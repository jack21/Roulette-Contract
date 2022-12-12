// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@chainlink/contracts/src/v0.8/VRFV2WrapperConsumerBase.sol";

import "hardhat/console.sol";

contract Roulette is Ownable, Pausable, ReentrancyGuard, VRFV2WrapperConsumerBase {
  // ------------------- 輪盤基本屬性 -------------------
  uint256 public betAmount = 100000000000000000; // 0.1 ETH，每次下注的金額
  uint256 public maxAmountAllowedInTheBank = 2000000000000000000; // 2 ether，銀行最多存放多少錢
  uint8[] public payouts; // 賠率 [2, 3, 3, 2, 2, 36]
  uint8[] public numberRange; // 每種 Type 可下注的數字 [1, 2, 2, 1, 1, 36]

  uint256 public lastBetId = 0;

  mapping(uint256 => uint256) public requestIdBetIdMap; // Chainlink 用，記錄 RequestId <=> BetId

  struct BetInfo {
    uint256 betId;
    address player;
    uint256 amount; // 參加者投入的金額
    uint256 randomNumber; // chainlink random number
    uint256 rewardAmount;
    uint256 betTimestamp;
    uint8 betType; // 投注的類型
    uint8 betNumber; // 投注的數字
    bool isDraw; // is chainlink random number callback
    bool isWin;
    bool isClaimed;
  }

  mapping(uint256 => BetInfo) public betInfoMap; // bet id -> BetInfo
  mapping(address => uint256[]) public playerBets; // Bet Player => BetId

  event ChainLinkRandomNumber(uint256 indexed requestId, uint256 indexed betId, uint256 number);
  event Bet(address indexed player, uint256 indexed betId, uint256 requestId, uint256 betAmount, uint8 betType, uint8 betNumber);
  event BetResult(address indexed player, uint256 indexed betId, bool indexed isWin, uint256 rewardAmount);
  event Claim(address indexed player, uint256 betId, uint256 rewardAmount);

  constructor(address linkToken, address vrfWrapper) VRFV2WrapperConsumerBase(linkToken, vrfWrapper) {
    payouts = [2, 3, 3, 2, 2, 36]; // 賠率
    numberRange = [1, 2, 2, 1, 1, 36]; // 每種 Type 可下注的數字
  }

  // ------------------- Player -------------------

  /**
   * 下注
   */
  function bet(uint8 _betType, uint8 _betNumber) external payable whenNotPaused returns (uint256) {
    /*
      A bet is valid when:
      0 - need genesis start
      1 - the value of the bet is correct (=betAmount)
      2 - betType is known (between 0 and 5)
      3 - the option betted is valid
      4 - the bank has sufficient funds to pay the bet
    */
    require(msg.value == betAmount, "Bet amount is incorrect"); // 1
    require(_betType >= 0 && _betType <= 5, "invalid bet type"); // 2
    require(_betNumber >= 0 && _betNumber <= numberRange[_betType], "invalid number"); // 3

    // 準備 BetInfo
    lastBetId++;
    uint256 _betId = lastBetId;
    BetInfo memory betInfo = BetInfo({
      player: msg.sender, //
      betId: _betId, //
      amount: msg.value, //
      betType: _betType, //
      betNumber: _betNumber, //
      randomNumber: 0,
      betTimestamp: block.timestamp,
      isDraw: false, //
      isWin: false, //
      rewardAmount: 0, //
      isClaimed: false //
    });
    betInfoMap[_betId] = betInfo;

    // 處理 UserBets
    playerBets[msg.sender].push(_betId);

    // request Chainlink random
    // whatever set gas limit to 100000, 50000, 30000, it always cost 0.25 LINK,
    // but lower gas limit will cause fulfillRandomWords() out of gas, so 100000 gas limit should be properly
    uint256 _requestId = requestRandomness(100000, 3, 1);
    requestIdBetIdMap[_requestId] = _betId;

    emit Bet(msg.sender, _betId, _requestId, msg.value, _betType, _betNumber);

    return _betId;
  }

  /**
   * ChainLink random number callback function
   */
  function fulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords) internal override {
    uint256 _randomNumber = _randomWords[0] % 36;
    uint256 _betId = requestIdBetIdMap[_requestId];
    emit ChainLinkRandomNumber(_requestId, _betId, _randomNumber);
    if (_betId == 0) {
      revert("betId not found");
    }

    // update BetInfo
    BetInfo storage _betInfo = betInfoMap[_betId];
    require(!_betInfo.isDraw, "gen random number callback, but drawed");
    _betInfo.isDraw = true;
    _betInfo.randomNumber = _randomNumber;
    bool _win = _isWin(_betInfo, _randomNumber);
    _betInfo.isWin = _win;

    // reward
    uint256 _betReward = 0;
    if (_win) {
      _betReward = betAmount * payouts[_betInfo.betType];
      _betInfo.rewardAmount = _betReward;
    }

    emit BetResult(msg.sender, _betId, _win, _betReward);
  }

  /**
   * 用戶領錢
   */
  function claim(uint256[] calldata _betIds) external nonReentrant notContract {
    // calculate reward
    uint256 _reward;
    for (uint256 j = 0; j < _betIds.length; j++) {
      uint256 _betId = _betIds[j];
      BetInfo storage _betInfo = betInfoMap[_betId];
      require(_betInfo.amount > 0, "!betInfo");
      require(_betInfo.player == msg.sender, "!player");
      require(_betInfo.isDraw, "!draw");
      require(_betInfo.isWin, "!win");
      require(!_betInfo.isClaimed, "claimed");
      _betInfo.isClaimed = true;
      _reward += _betInfo.rewardAmount;
      emit Claim(msg.sender, _betId, _betInfo.rewardAmount);
    }

    // transfer
    if (_reward > 0) {
      _safeTransferETH(msg.sender, _reward);
    }
  }

  /**
   * check is the bet win
   */
  function isWin(uint256 _betId, uint256 _number) external view returns (bool) {
    BetInfo memory _betInfo = betInfoMap[_betId];
    require(_betInfo.amount > 0, "Bet id not found");
    return _isWin(_betInfo, _number);
  }

  /**
   * check is the bet win
   * Depending on the BetType, number will be:
   * [0] color: 0 for BLACK, 1 for RED
   * [1] column: 0 for 1ST, 1 for 2ND, 2 for 3RD
   * [2] dozen: 0 for 1-12, 1 for 13-24, 2 for 25-36
   * [3] eighteen: 0 for 1-18, 1 for 19-36
   * [4] modulus: 0 for EVEN, 1 for ODD
   * [5] number: NUMBER
   */
  function _isWin(BetInfo memory _betInfo, uint256 _randomNumber) internal pure returns (bool) {
    bool result = false;
    uint256 _betNumber = _betInfo.betNumber;
    if (_betInfo.betType == 0) {
      if (_betNumber == 0) result = (_randomNumber % 2 == 0); /* bet on BLACK */
      if (_betNumber == 1) result = (_randomNumber % 2 == 1); /* bet on RED */
    } else if (_betInfo.betType == 1) {
      if (_betNumber == 0) result = (_randomNumber % 3 == 0); /* bet on 1ST */
      if (_betNumber == 1) result = (_randomNumber % 3 == 1); /* bet on 2ND */
      if (_betNumber == 2) result = (_randomNumber % 3 == 2); /* bet on 3RD */
    } else if (_betInfo.betType == 2) {
      if (_betNumber == 0) result = (_randomNumber <= 12); /* bet on 1-12 */
      if (_betNumber == 1) result = (_randomNumber > 12 && _randomNumber <= 24); /* bet on 13-24 */
      if (_betNumber == 2) result = (_randomNumber > 24); /* bet on 25-36 */
    } else if (_betInfo.betType == 3) {
      if (_betNumber == 0) result = (_randomNumber <= 18); /* bet on low 1-18 */
      if (_betNumber == 1) result = (_randomNumber >= 19); /* bet on high 19-36 */
    } else if (_betInfo.betType == 4) {
      if (_betNumber == 0) result = (_randomNumber % 2 == 0); /* bet on EVEN */
      if (_betNumber == 1) result = (_randomNumber % 2 == 1); /* bet on ODD */
    } else if (_betInfo.betType == 5) {
      result = (_betNumber == _randomNumber) || (_betNumber == 36 && _randomNumber == 0); /* bet on number */
    }
    return result;
  }

  /**
   * 取得用戶投注過的 BetIds
   */
  function getPlayerBetIds(address player) external view returns (uint256[] memory) {
    return playerBets[player];
  }

  function getStatus() public view returns (uint256, address, address) {
    return (
      LINK.balanceOf(address(this)), // roulette balance
      address(LINK),
      address(VRF_V2_WRAPPER)
    );
  }

  function getBetInfo(uint256 _betId) external view returns (BetInfo memory) {
    return betInfoMap[_betId];
  }

  function calculateRequestPrice(uint32 callbackGasLimit) external view returns (uint256) {
    return VRF_V2_WRAPPER.calculateRequestPrice(callbackGasLimit);
  }

  // ------------------- Owner -------------------

  /**
   * Allow withdraw of Link tokens from the contract
   */
  function withdrawLink() public onlyOwner {
    require(LINK.transfer(msg.sender, LINK.balanceOf(address(this))), "Unable to transfer");
  }

  /**
   * 項目方注入資金
   */
  function addFund() external payable {}

  function balance() external view returns (uint256) {
    return address(this).balance;
  }

  /**
   * 項目方提款
   */
  function withdraw(uint256 _amount) external onlyOwner {
    // TODO 要檢查提領後的金額，要滿足預備金
    _safeTransferETH(owner(), _amount);
  }

  /**
   * 自殺
   */
  function kill() external onlyOwner {
    selfdestruct(payable(owner()));
  }

  function pause() external whenNotPaused onlyOwner {
    _pause();
  }

  function unpause() external whenPaused onlyOwner {
    _unpause();
  }

  // ------------------- Modifier -------------------

  modifier notContract() {
    require(!_isContract(msg.sender), "Contract not allowed");
    require(msg.sender == tx.origin, "Proxy contract not allowed");
    _;
  }

  function _safeTransferETH(address to, uint256 value) internal {
    console.log("here1: %s -> %s", to, value);
    require(to != address(0), "invalid transfer address");
    console.log("here2");
    require(value > 0, "transfer amount = 0");
    console.log("here3");
    (bool sent, ) = payable(to).call{ value: value }("");
    console.log("here4: %s", sent);
    require(sent, "!transfer");
  }

  function _isContract(address account) internal view returns (bool) {
    uint256 size;
    assembly {
      size := extcodesize(account)
    }
    return size > 0;
  }
}
