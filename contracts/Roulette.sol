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
  uint8[] public betNumberRange; // 每種 Type 可下注的數字 [1, 2, 2, 1, 1, 36]

  uint256 public lastBetId = 0;

  mapping(uint256 => uint256) public requestIdBetIdMap; // Chainlink 用，記錄 RequestId <=> BetId

  struct BetInfo {
    uint256 betId;
    address player;
    uint256 betAmount;
    uint256 randomNumber; // chainlink random number
    uint256 rewardAmount;
    uint256 betTimestamp;
    uint8 winCount;
    uint8[] betTypes; // 投注的類型
    uint8[] betNumbers; // 投注的數字
    bool isDraw; // is chainlink random number callback
    bool isClaimed;
  }

  mapping(uint256 => BetInfo) public betInfoMap; // bet id -> BetInfo
  mapping(address => uint256[]) public playerBets; // Bet Player => BetId

  event ChainLinkRandomNumber(uint256 indexed requestId, uint256 indexed betId, uint256 number);
  event Bet(address indexed player, uint256 indexed betId, uint256 requestId, uint256 betAmount, uint8[] betTypes, uint8[] betNumbers);
  event BetResult(address indexed player, uint256 indexed betId, uint256 rewardAmount);
  event Claim(address indexed player, uint256 betId, uint256 rewardAmount);

  constructor(address linkToken, address vrfWrapper) VRFV2WrapperConsumerBase(linkToken, vrfWrapper) {
    payouts = [2, 3, 3, 2, 2, 36]; // 賠率
    betNumberRange = [1, 2, 2, 1, 1, 36]; // 每種 Type 可下注的數字
  }

  // ------------------- Player -------------------

  /**
   * 下注
   */
  function bet(uint8[] memory _betTypes, uint8[] memory _betNumbers) external payable whenNotPaused returns (uint256) {
    require(_betTypes.length > 0 && _betNumbers.length > 0, "length == 0"); // 0
    require(_betTypes.length == _betNumbers.length, "length not match"); // 0
    require(msg.value == betAmount * _betTypes.length, "Bet amount is incorrect"); // 1

    for (uint i = 0; i < _betTypes.length; i++) {
      uint _betType = _betTypes[i];
      uint _betNumber = _betNumbers[i];
      require(_betType >= 0 && _betType <= 5, "invalid bet type"); // 2
      require(_betNumber >= 0 && _betNumber <= betNumberRange[_betType], "invalid number"); // 3
    }
    // 準備 BetInfo
    lastBetId++;
    uint256 _betId = lastBetId;
    BetInfo memory betInfo = BetInfo({
      player: msg.sender, //
      betId: _betId, //
      betAmount: betAmount, //
      betTypes: _betTypes, //
      betNumbers: _betNumbers, //
      randomNumber: 0,
      betTimestamp: block.timestamp,
      isDraw: false, //
      winCount: 0, //
      rewardAmount: 0, //
      isClaimed: false //
    });
    betInfoMap[_betId] = betInfo;

    // request Chainlink random
    // whatever gas limit is 100000, 50000, 30000, it always cost 0.25 LINK,
    // but lower gas limit will cause fulfillRandomWords() out of gas, so 100000 gas limit should be properly
    uint256 _requestId = requestRandomness(100000, 3, 1);

    // 處理 BetId
    playerBets[msg.sender].push(_betId);
    requestIdBetIdMap[_requestId] = _betId;
    emit Bet(msg.sender, _betId, _requestId, msg.value, _betTypes, _betNumbers);

    return _betId;
  }

  /**
   * ChainLink random number callback function
   */
  function fulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords) internal override {
    uint256 _randomNumber = _randomWords[0] % 36;
    uint256 _betId = requestIdBetIdMap[_requestId];
    if (_betId == 0) {
      revert("betIds not found");
    }
    emit ChainLinkRandomNumber(_requestId, _betId, _randomNumber);

    // update BetInfo
    BetInfo storage _betInfo = betInfoMap[_betId];
    require(!_betInfo.isDraw, "drawed");
    _betInfo.isDraw = true;
    _betInfo.randomNumber = _randomNumber;

    // is win?
    uint8[] memory _betTypes = _betInfo.betTypes;
    uint8[] memory _betNumbers = _betInfo.betNumbers;
    uint256 _betAmount = _betInfo.betAmount;
    uint256 _betReward = 0;
    for (uint i = 0; i < _betTypes.length; i++) {
      uint8 _betType = _betTypes[i];
      uint8 _betNumber = _betNumbers[i];
      bool _win = _isWin(_betType, _betNumber, _randomNumber);
      if (_win) {
        _betReward += _betAmount * payouts[_betType];
      }
    }
    _betInfo.rewardAmount = _betReward;

    emit BetResult(msg.sender, _betId, _betReward);
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
      require(_betInfo.betAmount > 0, "!betInfo");
      require(_betInfo.player == msg.sender, "!player");
      require(_betInfo.isDraw, "!draw");
      require(_betInfo.rewardAmount > 0, "!win");
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
   * Depending on the BetType, number will be:
   * [0] color: 0 for BLACK, 1 for RED
   * [1] column: 0 for 1ST, 1 for 2ND, 2 for 3RD
   * [2] dozen: 0 for 1-12, 1 for 13-24, 2 for 25-36
   * [3] eighteen: 0 for 1-18, 1 for 19-36
   * [4] modulus: 0 for EVEN, 1 for ODD
   * [5] number: NUMBER
   */
  function _isWin(uint8 _betType, uint8 _betNumber, uint256 _randomNumber) internal pure returns (bool) {
    bool result = false;
    if (_betType == 0) {
      if (_betNumber == 0) result = isBlack(_randomNumber); /* bet on BLACK */
      if (_betNumber == 1) result = !isBlack(_randomNumber); /* bet on RED */
    } else if (_betType == 1) {
      if (_betNumber == 0) result = (_randomNumber % 3 == 1); /* bet on 1ST */
      if (_betNumber == 1) result = (_randomNumber % 3 == 2); /* bet on 2ND */
      if (_betNumber == 2) result = (_randomNumber % 3 == 0); /* bet on 3RD */
    } else if (_betType == 2) {
      if (_betNumber == 0) result = (_randomNumber <= 12); /* bet on 1-12 */
      if (_betNumber == 1) result = (_randomNumber > 12 && _randomNumber <= 24); /* bet on 13-24 */
      if (_betNumber == 2) result = (_randomNumber > 24); /* bet on 25-36 */
    } else if (_betType == 3) {
      if (_betNumber == 0) result = (_randomNumber <= 18); /* bet on low 1-18 */
      if (_betNumber == 1) result = (_randomNumber >= 19); /* bet on high 19-36 */
    } else if (_betType == 4) {
      if (_betNumber == 0) result = (_randomNumber % 2 == 0); /* bet on EVEN */
      if (_betNumber == 1) result = (_randomNumber % 2 == 1); /* bet on ODD */
    } else if (_betType == 5) {
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

  function isBlack(uint256 number) private pure returns (bool) {
    return
      number == 2 ||
      number == 4 ||
      number == 6 ||
      number == 8 ||
      number == 10 ||
      number == 11 ||
      number == 13 ||
      number == 15 ||
      number == 17 ||
      number == 20 ||
      number == 22 ||
      number == 24 ||
      number == 26 ||
      number == 28 ||
      number == 29 ||
      number == 31 ||
      number == 33 ||
      number == 35;
  }

  // ------------------- Owner -------------------

  /**
   * Allow withdraw of Link tokens from the contract
   */
  function withdrawLink() public onlyOwner {
    require(LINK.transfer(msg.sender, LINK.balanceOf(address(this))), "Unable to transfer");
  }

  receive() external payable {}

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
    // console.log("here1: %s -> %s", to, value);
    require(to != address(0), "invalid transfer address");
    // console.log("here2");
    require(value > 0, "transfer amount = 0");
    // console.log("here3");
    require(value <= address(this).balance, "ETH not enough");
    (bool sent, ) = payable(to).call{ value: value }("");
    // console.log("here4: %s", sent);
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
