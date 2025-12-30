// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/lib/contracts/libraries/TransferHelper.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(
        address owner,
        address spender
    ) external view returns (uint256);
}

contract MultDistributionToken is Ownable {
    address private immutable BKC;
    constructor(address bkc) Ownable(msg.sender) {
        BKC = bkc;
    }

    function multDistribution(
        address[] memory _to,
        uint256[] memory _amount
    ) public onlyOwner {
        require(_to.length == _amount.length, "Invalid input");
        require(_to.length > 0 && _amount.length > 0, "Invalid input");
        uint256 contractBalance = IERC20(BKC).balanceOf(address(this));
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < _to.length; i++) {
            require(_to[i] != address(0), "Invalid input");
            require(_amount[i] > 0, "Invalid input");
            totalAmount += _amount[i];
        }
        require(totalAmount <= contractBalance, "Invalid input");
        for (uint256 i = 0; i < _to.length; i++) {
            TransferHelper.safeTransfer(BKC, _to[i], _amount[i]);
        }
    }

    function transferToken(address to, uint256 amount) public onlyOwner {
        require(to != address(0), "Invalid input");
        require(amount > 0, "Invalid input");
        uint256 contractBalance = IERC20(BKC).balanceOf(address(this));
        require(contractBalance >= amount, "Invalid input");
        TransferHelper.safeTransfer(BKC, to, amount);
    }

    function getContractBalance() public view returns (uint256) {
        return IERC20(BKC).balanceOf(address(this));
    }
}
