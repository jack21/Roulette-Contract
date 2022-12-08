// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@chainlink/contracts/src/v0.8/interfaces/VRFV2WrapperInterface.sol";
import "@chainlink/contracts/src/v0.8/VRFV2WrapperConsumerBase.sol";

contract MockVRFV2Wrapper is VRFV2WrapperInterface {
  uint256 requestId;

  function lastRequestId() external view returns (uint256) {
    return block.timestamp;
  }

  function calculateRequestPrice(uint32 _callbackGasLimit) external pure returns (uint256) {
    return _callbackGasLimit * 100;
  }

  function estimateRequestPrice(uint32 _callbackGasLimit, uint256 _requestGasPriceWei) external pure returns (uint256) {
    return _callbackGasLimit * _requestGasPriceWei;
  }

  // for test
  function rawFulfillRandomWords(address to, uint256 _requestId, uint256[] memory _randomWords) external {
    VRFV2WrapperConsumerBase(to).rawFulfillRandomWords(_requestId, _randomWords);
  }
}
