// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@chainlink/contracts/src/v0.8/VRFV2WrapperConsumerBase.sol";

// import "hardhat/console.sol";

contract Roulette is Ownable, Pausable, ReentrancyGuard, VRFV2WrapperConsumerBase {
  // ------------------- 輪盤基本屬性 -------------------
  uint256 public betAmount = 1000000000000000; // 0.001 ETH，每次下注的金額
  // TODO 之後要實作檢查預備金
  // uint256 necessaryBalance; // 預備金的數量（防止不夠賠）
  uint256 public maxAmountAllowedInTheBank = 2000000000000000000; // 2 ether，銀行最多存放多少錢
  uint8[] public payouts; // 賠率 [2, 3, 3, 2, 2, 36]
  uint8[] public numberRange; // 每種 Type 可下注的數字 [1, 2, 2, 1, 1, 36]

  uint256 public lastBetId = 0;

  mapping(uint256 => uint256) public requestIdBetIdMap; // Chainlink 用，記錄 RequestId <=> Random Number
  mapping(uint256 => uint256[]) public roundBetIds; // Key: RoundId, Value: 下注的 BetId，對應到 betInfos 的 index

  /*
    Depending on the BetType, number will be:
    [0] color: 0 for black, 1 for red
    [1] column: 0 for left, 1 for middle, 2 for right
    [2] dozen: 0 for first, 1 for second, 2 for third
    [3] eighteen: 0 for low, 1 for high
    [4] modulus: 0 for even, 1 for odd
    [5] number: number
  */
  struct BetInfo {
    uint256 betId;
    address player;
    uint256 amount; // 參加者投入的金額
    uint256 randomNumber; // chainlink random number
    uint8 betType; // 投注的類型
    uint8 betNumber; // 投注的數字
    bool isOpen; // is chainlink random number callback
    bool isWin;
  }

  mapping(uint256 => BetInfo) public betInfoMap;
  mapping(address => uint256[]) public playerBets; // Bet Player => BetId
  mapping(address => bool) public playerBetting; // Bet Player => is betting

  // event ChainLinkRandomRequest(uint256 indexed requestId, uint256 indexed betId);
  event ChainLinkRandomNumber(uint256 indexed requestId, uint256 indexed betId, uint256 number);
  event Bet(address indexed player, uint256 indexed betId, uint256 requestId, uint256 betAmount, uint8 betType, uint8 betNumber);
  event BetResult(address indexed player, uint256 indexed betId, bool indexed isWin, uint256 rewardAmount, uint256 p2eRewardAmount);

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
      3 - the option betted is valid (don't bet on 37!)
      4 - the bank has sufficient funds to pay the bet
    */
    require(msg.value == betAmount, "Bet amount is incorrect"); // 1
    require(_betType >= 0 && _betType <= 5, "invalid bet type"); // 2
    require(_betNumber >= 0 && _betNumber <= numberRange[_betType], "invalid number"); // 3
    // TODO 之後要實作檢查預備金
    // uint256 payoutForThisBet = payouts[_betType] * msg.value; // 贏可以獲得的金額
    // uint256 provisionalBalance = necessaryBalance + payoutForThisBet; // 金庫至少要有多少金額
    // require(provisionalBalance < address(this).balance, "balance is not sufficient"); // 4

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
      isOpen: false, //
      isWin: false //
    });
    betInfoMap[_betId] = betInfo;

    // 處理 UserBets
    playerBets[msg.sender].push(_betId);
    playerBetting[msg.sender] = true;

    // 調整預備金
    // TODO 之後要實作檢查預備金
    // necessaryBalance += payoutForThisBet;

    // request Chainlink random
    uint256 _requestId = requestRandomness(100000, 3, 1);
    requestIdBetIdMap[_requestId] = _betId;

    // TODO Bet Event add requestId
    emit Bet(msg.sender, _betId, _requestId, msg.value, _betType, _betNumber);

    return _betId;
  }

  /**
   * ChainLink random number callback function
   */
  function fulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords) internal override {
    uint256 _randomNumber = _randomWords[0] % 37;
    uint256 _betId = requestIdBetIdMap[_requestId];
    emit ChainLinkRandomNumber(_requestId, _betId, _randomNumber);
    if (_betId == 0) {
      revert("betId not found");
    }

    // update BetInfo
    BetInfo storage _betInfo = betInfoMap[_betId];
    require(!_betInfo.isOpen, "gen random number callback, but bet opened");
    _betInfo.isOpen = true;
    _betInfo.randomNumber = _randomNumber;
    bool _isWin = _isWin(_betInfo, _randomNumber);
    _betInfo.isWin = _isWin;

    // reward
    uint256 _betReward = 0;
    uint256 _betP2eReward = 0;
    if (_isWin) {
      _betReward = betAmount * payouts[_betInfo.betType];
    }

    emit BetResult(msg.sender, _betId, _isWin, _betReward, _betP2eReward);
  }

  /**
   * 判斷是否獲勝
   */
  function isWin(uint256 _betId, uint256 _number) external view returns (bool) {
    BetInfo memory _betInfo = betInfoMap[_betId];
    require(_betInfo.amount > 0, "Bet id not found");
    return _isWin(_betInfo, _number);
  }

  /**
   * 判斷是否獲勝
   */
  function _isWin(BetInfo memory _betInfo, uint256 _randomNumber) internal pure returns (bool) {
    bool _isWin = false;
    uint256 _betNumber = _betInfo.betNumber;
    if (_randomNumber == 0) {
      _isWin = (_betInfo.betType == 5 && _betNumber == 0); /* bet on 0 */
    } else {
      if (_betInfo.betType == 5) {
        _isWin = (_betNumber == _randomNumber); /* bet on number */
      } else if (_betInfo.betType == 4) {
        if (_betNumber == 0) _isWin = (_randomNumber % 2 == 0); /* bet on even */
        if (_betNumber == 1) _isWin = (_randomNumber % 2 == 1); /* bet on odd */
      } else if (_betInfo.betType == 3) {
        if (_betNumber == 0) _isWin = (_randomNumber <= 18); /* bet on low 18s */
        if (_betNumber == 1) _isWin = (_randomNumber >= 19); /* bet on high 18s */
      } else if (_betInfo.betType == 2) {
        if (_betNumber == 0) _isWin = (_randomNumber <= 12); /* bet on 1st dozen */
        if (_betNumber == 1) _isWin = (_randomNumber > 12 && _randomNumber <= 24); /* bet on 2nd dozen */
        if (_betNumber == 2) _isWin = (_randomNumber > 24); /* bet on 3rd dozen */
      } else if (_betInfo.betType == 1) {
        if (_betNumber == 0) _isWin = (_randomNumber % 3 == 1); /* bet on left column */
        if (_betNumber == 1) _isWin = (_randomNumber % 3 == 2); /* bet on middle column */
        if (_betNumber == 2) _isWin = (_randomNumber % 3 == 0); /* bet on right column */
      } else if (_betInfo.betType == 0) {
        if (_betNumber == 0) {
          /* bet on black */
          if (_randomNumber <= 10 || (_randomNumber >= 20 && _randomNumber <= 28)) {
            _isWin = (_randomNumber % 2 == 0);
          } else {
            _isWin = (_randomNumber % 2 == 1);
          }
        } else {
          /* bet on red */
          if (_randomNumber <= 10 || (_randomNumber >= 20 && _randomNumber <= 28)) {
            _isWin = (_randomNumber % 2 == 1);
          } else {
            _isWin = (_randomNumber % 2 == 0);
          }
        }
      }
    }
    return _isWin;
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

  function isPlayerBetting(address player) external view returns (bool) {
    return playerBetting[player];
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
  function addFund() public payable {}

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
    require(to != address(0), "invalid transfer address");
    require(value > 0, "transfer amount = 0");
    payable(to).transfer(value);
  }

  function _isContract(address account) internal view returns (bool) {
    uint256 size;
    assembly {
      size := extcodesize(account)
    }
    return size > 0;
  }
}
