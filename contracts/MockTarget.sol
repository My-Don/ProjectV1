// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title MockTarget
 * @notice 测试 execute / executeBatch 调用目标
 */
contract MockTarget {
    uint256 public number;
    address public lastSender;
    uint256 public lastValue;

    event NumberSet(uint256 number, address sender, uint256 value);

    receive() external payable {
        lastSender = msg.sender;
        lastValue = msg.value;
    }

    function setNumber(uint256 newNumber) external payable returns (uint256) {
        number = newNumber;
        lastSender = msg.sender;
        lastValue = msg.value;

        emit NumberSet(newNumber, msg.sender, msg.value);

        return newNumber + 1;
    }

    function add(uint256 a, uint256 b) external pure returns (uint256) {
        return a + b;
    }

    function revertWithMessage() external pure {
        revert("MOCK_TARGET_REVERT");
    }
}
