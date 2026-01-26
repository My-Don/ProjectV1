// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";


interface IUniswapV2Pair {
    function approve(address spender, uint value) external returns (bool);
}


contract SwapTrade is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    address public immutable uniswapV2Router;
    address public immutable factory;
    address public immutable bkc;
    address public immutable snc;
    address public immutable usdt;

    // 最大允许滑点：500 = 5%
    uint256 public constant MAX_SLIPPAGE_BPS = 500;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    struct LiquidityParams {
        address tokenA;
        address tokenB;
        uint256 amountA;
        uint256 amountB;
        uint256 amountAMin;
        uint256 amountBMin;
        address to;
        uint256 deadline;
    }

    event LiquidityAdded(
        address indexed tokenA,
        address indexed tokenB,
        uint256 amountA,
        uint256 amountB,
        address indexed to
    );

    event LiquidityRemoved(
        address indexed lpToken,
        uint256 liquidity,
        address indexed tokenA,
        address indexed tokenB,
        address to
    );

    event SwapEvent(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    constructor(
        address _bkc,
        address _snc,
        address _usdt,
        address _uniswapV2Router
    ) Ownable(msg.sender) {
        require(
            _uniswapV2Router != address(0) &&
                _bkc != address(0) &&
                _snc != address(0) &&
                _usdt != address(0),
            "zero address"
        );

        uniswapV2Router = _uniswapV2Router;

        (bool success, bytes memory data) = uniswapV2Router.staticcall(
            abi.encodeWithSignature("factory()")
        );
        require(success && data.length > 0, "factory() failed");
        factory = abi.decode(data, (address));

        bkc = _bkc;
        snc = _snc;
        usdt = _usdt;
    }

    /*
     * 统一处理 approve 
     */
    function _approveIfNeeded(address token, uint256 amount) internal {
       if (token == address(0)) return;

        uint256 allowance = IERC20(token).allowance(address(this), uniswapV2Router);
        if (allowance >= amount) return;

        if (token == usdt) {
        // USDT 需要先清零再授权
        IERC20(usdt).safeIncreaseAllowance(uniswapV2Router, 0);
        IERC20(usdt).safeIncreaseAllowance(uniswapV2Router, type(uint256).max);
        } else {
            // 标准 ERC20：直接授权 max（避免多次 approve）
            IERC20(token).safeIncreaseAllowance(uniswapV2Router, type(uint256).max);
        }
    }

    /*
     * 获取交易对
     */
    function _getPair(
        address tokenA,
        address tokenB
    ) internal view returns (address pair) {
        (bool ok, bytes memory data) = factory.staticcall(
            abi.encodeWithSignature("getPair(address,address)", tokenA, tokenB)
        );
        require(ok && data.length >= 32, "getPair failed");
        pair = abi.decode(data, (address));
    }

    /*
     * 选最优路径：
     * 1️⃣ 直池
     * 2️⃣ token → USDT → token
     */
    /*
     * 选择最优交易路径：
     * 1️⃣ 直接交易对
     * 2️⃣ 通过 USDT 中转：token → USDT → token
     */
    function _bestPath(
        address tokenIn,
        address tokenOut
    ) internal view returns (address[] memory path) {
        // 检查是否有直接交易对
        address directPair = _getPair(tokenIn, tokenOut);
        if (directPair != address(0)) {
            path = new address[](2);
            path[0] = tokenIn;
            path[1] = tokenOut;
        } else {
            // 通过 USDT 中转
            address pairInUsdt = _getPair(tokenIn, usdt);
            address pairOutUsdt = _getPair(usdt, tokenOut);
            require(
                pairInUsdt != address(0) && pairOutUsdt != address(0),
                "no effective trading path"
            );
            path = new address[](3);
            path[0] = tokenIn;
            path[1] = usdt;
            path[2] = tokenOut;
        }
    }

    /*
     * 链上报价（不实际执行交易）
     */
    function _quote(
        uint256 amountIn,
        address[] memory path
    ) internal view returns (uint256 amountOut) {
        (bool ok, bytes memory data) = uniswapV2Router.staticcall(
            abi.encodeWithSignature(
                "getAmountsOut(uint256,address[])",
                amountIn,
                path
            )
        );
        require(ok && data.length > 0, "quote failed");

        uint256[] memory amounts = abi.decode(data, (uint256[]));
        amountOut = amounts[amounts.length - 1];
    }

    /*
     * 根据滑点算最小接收数量
     */
    function _amountOutMin(
        uint256 amountOut,
        uint256 slippageBps
    ) internal pure returns (uint256) {
        return (amountOut * (BPS_DENOMINATOR - slippageBps)) / BPS_DENOMINATOR;
    }

    /*
     * swap 核心逻辑（支持自动路径）
     */
    function _swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline
    ) internal returns (uint256 amountOut) {
        require(to != address(0), "zero address");

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        _approveIfNeeded(tokenIn, amountIn);

        address[] memory path = _bestPath(tokenIn, tokenOut);

        uint256 finalDeadline = deadline == 0
            ? block.timestamp + 300
            : deadline;

        (bool success, bytes memory data) = uniswapV2Router.call(
            abi.encodeWithSignature(
                "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
                amountIn,
                amountOutMin,
                path,
                to,
                finalDeadline
            )
        );

        require(success && data.length > 0, "router call failed");

        uint256[] memory amounts = abi.decode(data, (uint256[]));
        amountOut = amounts[amounts.length - 1];
    }

    /*
     * 前端用：预测能换多少 + 实际路径
     */
    function quote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 amountOut, address[] memory path) {
        path = _bestPath(tokenIn, tokenOut);
        amountOut = _quote(amountIn, path);
    }

    /*
     * 自动算滑点的 swap
     *
     * slippageBps：
     * 100 = 1%
     * 500 = 5%
     */
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 slippageBps,
        address to,
        uint256 deadline
    ) external nonReentrant returns (uint256 amountOut) {
        require(
            tokenIn != address(0) && tokenOut != address(0) && to != address(0),
            "zero address"
        );
        require(amountIn > 0, "amountIn = 0");
        require(slippageBps <= MAX_SLIPPAGE_BPS, "slippage too large");

        // 获取最佳交易路径
        address[] memory path = _bestPath(tokenIn, tokenOut);

        // 获取报价
        uint256 quotedOut = _quote(amountIn, path);
        require(quotedOut > 0, "no liquidity");

        // 计算最小接收数量
        uint256 minOut = _amountOutMin(quotedOut, slippageBps);
        amountOut = _swap(tokenIn, tokenOut, amountIn, minOut, to, deadline);

        emit SwapEvent(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    function addLiquidity(
        LiquidityParams memory p
    ) external onlyOwner nonReentrant {
        require(
            p.tokenA != address(0) &&
                p.tokenB != address(0) &&
                p.to != address(0),
            "zero address"
        );

        IERC20(p.tokenA).safeTransferFrom(owner(), address(this), p.amountA);
        IERC20(p.tokenB).safeTransferFrom(owner(), address(this), p.amountB);

        _approveIfNeeded(p.tokenA, p.amountA);
        _approveIfNeeded(p.tokenB, p.amountB);

        uint256 finalDeadline = p.deadline == 0
            ? block.timestamp + 300
            : p.deadline;

        (bool success, ) = uniswapV2Router.call(
            abi.encodeWithSignature(
                "addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256)",
                p.tokenA,
                p.tokenB,
                p.amountA,
                p.amountB,
                p.amountAMin,
                p.amountBMin,
                p.to,
                finalDeadline
            )
        );
        require(success, "addLiquidity failed");

        emit LiquidityAdded(p.tokenA, p.tokenB, p.amountA, p.amountB, p.to);
    }

    function removeLiquidity(
        address lpToken,
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external onlyOwner nonReentrant {
        require(lpToken != address(0) && to != address(0), "zero address");
        require(tokenA != address(0) && tokenB != address(0), "zero address");
        require(
            liquidity > 0,
            "the amount of liquidity must be greater than zero."
        );

        require(
            IERC20(lpToken).balanceOf(address(this)) >= liquidity,
            "insufficient LP balance"
        );

        address pair = _getPair(tokenA, tokenB);
        require(pair != address(0), "Pair not exist");
        require(pair == lpToken, "LP token mismatch");

        uint256 allowance = IERC20(lpToken).allowance(
            address(this),
            uniswapV2Router
        );
        if (allowance < liquidity) {
            IERC20(lpToken).safeIncreaseAllowance(uniswapV2Router, type(uint256).max);
        }

        uint256 finalDeadline = deadline == 0
            ? block.timestamp + 300
            : deadline;

        (bool success, ) = uniswapV2Router.call(
            abi.encodeWithSignature(
                "removeLiquidity(address,address,uint256,uint256,uint256,address,uint256)",
                tokenA,
                tokenB,
                liquidity,
                amountAMin,
                amountBMin,
                to,
                finalDeadline
            )
        );
        require(success, "removeLiquidity failed");
        emit LiquidityRemoved(lpToken, liquidity, tokenA, tokenB, to);
    }

    function withdraw(
        address[] calldata tokens,
        address to
    ) external onlyOwner {
        require(to != address(0), "to = zero");

        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 balance = IERC20(tokens[i]).balanceOf(address(this));
            if (balance > 0) {
                IERC20(tokens[i]).safeTransfer(to, balance);
            }
        }
    }
}
