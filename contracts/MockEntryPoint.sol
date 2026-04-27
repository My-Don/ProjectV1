// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    IEntryPoint,
    IAccount,
    PackedUserOperation
} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";

/**
 * @title MockEntryPoint
 * @notice 测试用 EntryPoint，不是生产合约
 *
 * 大白话：
 * - 这个合约只为了单元测试。
 * - 它模拟 EntryPoint 调用账户。
 * - 它实现 deposit / withdraw / getNonce。
 * - 它能低级调用账户的 execute / executeBatch / changeOwner / withdrawDepositTo。
 */
contract MockEntryPoint is IEntryPoint {
    mapping(address => uint256) private _deposits;
    mapping(address => mapping(uint192 => uint256)) private _nonces;

    event MockDeposited(address indexed account, uint256 amount);
    event MockWithdrawn(address indexed account, address indexed to, uint256 amount);

    receive() external payable {}

    function balanceOf(address account) external view override returns (uint256) {
        return _deposits[account];
    }

    function depositTo(address account) external payable override {
        _deposits[account] += msg.value;

        emit MockDeposited(account, msg.value);
    }

    function withdrawTo(
        address payable withdrawAddress,
        uint256 withdrawAmount
    ) external override {
        uint256 current = _deposits[msg.sender];

        require(current >= withdrawAmount, "MOCK_EP_INSUFFICIENT_DEPOSIT");

        unchecked {
            _deposits[msg.sender] = current - withdrawAmount;
        }

        (bool ok, ) = withdrawAddress.call{value: withdrawAmount}("");
        require(ok, "MOCK_EP_WITHDRAW_FAILED");

        emit MockWithdrawn(msg.sender, withdrawAddress, withdrawAmount);
    }

    function getNonce(
        address sender,
        uint192 key
    ) external view override returns (uint256 nonce) {
        return _nonces[sender][key];
    }

    function setNonce(address sender, uint192 key, uint256 nonce) external {
        _nonces[sender][key] = nonce;
    }

    function addStake(uint32) external payable override {}

    function unlockStake() external override {}

    function withdrawStake(address payable) external override {}

    function handleOps(
        PackedUserOperation[] calldata,
        address payable
    ) external override {}

    function handleAggregatedOps(
        IEntryPoint.UserOpsPerAggregator[] calldata,
        address payable
    ) external override {}

    /**
     * @notice 让 MockEntryPoint 调用账户。
     *
     * 大白话：
     * - 单元测试里，账户的 execute / changeOwner 等函数要求 msg.sender 是 EntryPoint。
     * - 测试脚本不能直接冒充 EntryPoint。
     * - 所以让这个 MockEntryPoint 去 call 账户。
     */
    function executeFromAccount(
        address account,
        bytes calldata callData
    ) external returns (bytes memory result) {
        (bool ok, bytes memory ret) = account.call(callData);

        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }

        return ret;
    }

    /**
     * @notice 带 ETH 调用账户。
     *
     * 大白话：
     * - 用来测试 execute / executeBatch 不是 payable。
     */
    function executeFromAccountWithValue(
        address account,
        bytes calldata callData
    ) external payable returns (bytes memory result) {
        (bool ok, bytes memory ret) = account.call{value: msg.value}(callData);

        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }

        return ret;
    }

    /**
     * @notice 让 MockEntryPoint 调用账户的 validateUserOp。
     */
    function validateAccount(
        address account,
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external returns (uint256 validationData) {
        return IAccount(account).validateUserOp(
            userOp,
            userOpHash,
            missingAccountFunds
        );
    }
}
