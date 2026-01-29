// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IUniswapV2Pair {
    function approve(address spender, uint value) external returns (bool);
}

/**
 * @title SwapTrade 合约
 * @dev 一个基于 Uniswap V2 的代币兑换和流动性管理合约
 * @notice 提供代币兑换、添加/移除流动性等功能，支持自动选择最优交易路径
 */
contract SwapTrade is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // 核心地址变量
    address public immutable uniswapV2Router; // Uniswap V2 路由器地址
    address public immutable factory;          // Uniswap V2 工厂地址
    address public immutable bkc;              // BKC 代币地址
    address public immutable snc;              // SNC 代币地址
    address public immutable usdt;             // USDT 代币地址

    // 滑点相关常量
    uint256 public constant MAX_SLIPPAGE_BPS = 500;     // 最大允许滑点：500 = 5%
    uint256 public constant BPS_DENOMINATOR = 10_000;   // 滑点计算分母（10000 = 100%）

    /**
     * @dev 添加流动性的参数结构体
     * @param tokenA 代币A地址
     * @param tokenB 代币B地址
     * @param amountA 代币A数量
     * @param amountB 代币B数量
     * @param amountAMin 代币A最小数量（防止滑点）
     * @param amountBMin 代币B最小数量（防止滑点）
     * @param to 流动性接收地址
     * @param deadline 交易截止时间
     */
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

    // 事件定义
    event LiquidityAdded(
        address indexed tokenA,      // tokenA合约地址
        address indexed tokenB,      // tokenB合约地址
        uint256 amountADesired,      // 期望的代币A数量
        uint256 amountBDesired,      // 期望的代币B数量
        uint256 amountAActual,       // 实际添加的代币A数量
        uint256 amountBActual,       // 实际添加的代币B数量
        uint256 liquidity,           // 获得的流动性代币数量
        address indexed to           // 流动性接收地址
    );

    event LiquidityRemoved(
        address indexed lpToken,     // 流动性代币地址
        uint256 liquidity,           // 移除的流动性数量
        uint256 amountA,             // 获得的代币A数量
        uint256 amountB,             // 获得的代币B数量
        address indexed tokenA,      // 代币A地址
        address indexed tokenB,      // 代币B地址
        address to                   // 接收地址
    );

    event SwapEvent(
        address indexed user,        // 发起兑换的用户地址
        address indexed tokenIn,     // 输入代币地址
        address indexed tokenOut,    // 输出代币地址
        uint256 amountIn,            // 输入代币数量
        uint256 amountOut            // 输出代币数量
    );

    event Withdraw(address indexed token, address indexed to, uint256 amount);

    /**
     * @dev 构造函数
     * @param _bkc BKC 代币地址
     * @param _snc SNC 代币地址
     * @param _usdt USDT 代币地址
     * @param _uniswapV2Router Uniswap V2 路由器地址
     */
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

        // 从路由器获取工厂地址
        (bool success, bytes memory data) = uniswapV2Router.staticcall(
            abi.encodeWithSignature("factory()")
        );
        require(success && data.length > 0, "factory() failed");
        factory = abi.decode(data, (address));

        bkc = _bkc;
        snc = _snc;
        usdt = _usdt;
    }

    /**
     * @dev 统一处理代币授权
     * @notice 自动处理需要先清零的代币（如 USDT），避免授权失败
     * @param token 代币地址
     * @param amount 授权数量
     */
    function _approveIfNeeded(address token, uint256 amount) internal {
        if (token == address(0)) return;

        // 检查当前授权是否足够
        uint256 allowance = IERC20(token).allowance(
            address(this),
            uniswapV2Router
        );
        if (allowance >= amount) return;

        // forceApprove 会自动处理需要先清零的代币（如 USDT）
        IERC20(token).forceApprove(uniswapV2Router, type(uint256).max);
    }

    /**
     * @dev 获取交易对地址
     * @param tokenA 代币A地址
     * @param tokenB 代币B地址
     * @return pair 交易对地址
     */
    function _getPair(
        address tokenA,
        address tokenB
    ) internal view returns (address pair) {
        // 获取交易对地址
        (bool ok, bytes memory data) = factory.staticcall(
            abi.encodeWithSignature("getPair(address,address)", tokenA, tokenB)
        );
        require(ok && data.length >= 32, "getPair failed");
        pair = abi.decode(data, (address));
    }

    /**
     * @dev 选择最优交易路径
     * @notice 比较直接交易对和通过 USDT 中转的路径，选择输出更多的路径
     * @param tokenIn 输入代币地址
     * @param tokenOut 输出代币地址
     * @param amountIn 输入代币数量
     * @return path 最优交易路径
     */
    function _bestPath(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (address[] memory path) {
        // 获取直接交易对和通过 USDT 中转的交易对
        address directPair = _getPair(tokenIn, tokenOut);
        address pairInUsdt = _getPair(tokenIn, usdt);
        address pairOutUsdt = _getPair(usdt, tokenOut);

        // 检查是否存在直接路径和 USDT 中转路径
        bool hasDirectPath = directPair != address(0);
        bool hasUsdtPath = pairInUsdt != address(0) &&
            pairOutUsdt != address(0) &&
            tokenIn != usdt &&
            tokenOut != usdt;

        // 确保至少存在一条有效路径
        require(hasDirectPath || hasUsdtPath, "no effective trading path");

        // 根据路径情况选择最优路径
        if (hasDirectPath && !hasUsdtPath) {
            // 只有直接路径
            path = new address[](2);
            path[0] = tokenIn;
            path[1] = tokenOut;
        } else if (!hasDirectPath && hasUsdtPath) {
            // 只有 USDT 中转路径
            path = new address[](3);
            path[0] = tokenIn;
            path[1] = usdt;
            path[2] = tokenOut;
        } else {
            // 两条路径都存在，比较输出选择更优的
            address[] memory directPath = new address[](2);
            directPath[0] = tokenIn;
            directPath[1] = tokenOut;

            address[] memory usdtPath = new address[](3);
            usdtPath[0] = tokenIn;
            usdtPath[1] = usdt;
            usdtPath[2] = tokenOut;

            // 分别获取两条路径的输出数量
            uint256 directOut = _quoteSafe(amountIn, directPath);
            uint256 usdtOut = _quoteSafe(amountIn, usdtPath);

            // 选择输出更大的路径
            if (usdtOut > directOut) {
                path = usdtPath;
            } else {
                path = directPath;
            }
        }
    }

    /**
     * @dev 链上报价（不实际执行交易）
     * @param amountIn 输入代币数量
     * @param path 交易路径
     * @return amountOut 预计输出代币数量
     */
    function _quote(
        uint256 amountIn,
        address[] memory path
    ) internal view returns (uint256 amountOut) {
        // 调用路由器的 getAmountsOut 方法获取报价
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

    /**
     * @dev 安全报价（失败时返回 0，用于路径比较）
     * @param amountIn 输入代币数量
     * @param path 交易路径
     * @return amountOut 预计输出代币数量，失败时返回 0
     */
    function _quoteSafe(
        uint256 amountIn,
        address[] memory path
    ) internal view returns (uint256 amountOut) {
        // 调用路由器的 getAmountsOut 方法获取报价
        (bool ok, bytes memory data) = uniswapV2Router.staticcall(
            abi.encodeWithSignature(
                "getAmountsOut(uint256,address[])",
                amountIn,
                path
            )
        );
        // 失败时返回 0
        if (!ok || data.length == 0) {
            return 0;
        }

        uint256[] memory amounts = abi.decode(data, (uint256[]));
        amountOut = amounts[amounts.length - 1];
    }

    /**
     * @dev 根据滑点计算最小接收数量
     * @param amountOut 预计输出数量
     * @param slippageBps 滑点（单位：基点，100 = 1%）
     * @return 考虑滑点后的最小接收数量
     */
    function _amountOutMin(
        uint256 amountOut,
        uint256 slippageBps
    ) internal pure returns (uint256) {
        return (amountOut * (BPS_DENOMINATOR - slippageBps)) / BPS_DENOMINATOR;
    }

    /**
     * @dev 代币兑换核心逻辑
     * @notice 支持自动选择最优交易路径
     * @param tokenIn 输入代币地址
     * @param tokenOut 输出代币地址
     * @param amountIn 输入代币数量
     * @param amountOutMin 最小输出数量（防止滑点）
     * @param to 接收地址
     * @param deadline 交易截止时间
     * @return amountOut 实际输出数量
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

        // 从用户地址转移代币到合约
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // 确保代币已授权给路由器
        _approveIfNeeded(tokenIn, amountIn);

        // 选择最优交易路径
        address[] memory path = _bestPath(tokenIn, tokenOut, amountIn);

        // 处理截止时间
        uint256 finalDeadline = deadline == 0
            ? block.timestamp + 300  // 默认 5 分钟
            : deadline;

        // 调用路由器执行兑换
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

        // 解码返回数据，获取实际输出数量
        uint256[] memory amounts = abi.decode(data, (uint256[]));
        amountOut = amounts[amounts.length - 1];
    }

    /**
     * @dev 前端用：预测能换多少代币 + 实际交易路径
     * @param tokenIn 输入代币地址
     * @param tokenOut 输出代币地址
     * @param amountIn 输入代币数量
     * @return amountOut 预计输出数量
     * @return path 实际交易路径
     */
    function quote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 amountOut, address[] memory path) {
        // 选择最优交易路径
        path = _bestPath(tokenIn, tokenOut, amountIn);
        // 获取报价
        amountOut = _quote(amountIn, path);
    }

    /**
     * @dev 自动算滑点的代币兑换
     * @param tokenIn 输入代币地址
     * @param tokenOut 输出代币地址
     * @param amountIn 输入代币数量
     * @param slippageBps 滑点（单位：基点，100 = 1%）
     * @param to 接收地址
     * @param deadline 交易截止时间
     * @return amountOut 实际输出数量
     */
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 slippageBps,
        address to,
        uint256 deadline
    ) external nonReentrant returns (uint256 amountOut) {
        // 检查输入参数
        require(
            tokenIn != address(0) && tokenOut != address(0) && to != address(0),
            "zero address"
        );
        require(amountIn > 0, "amountIn = 0");
        require(slippageBps <= MAX_SLIPPAGE_BPS, "slippage too large");

        // 获取最佳交易路径
        address[] memory path = _bestPath(tokenIn, tokenOut, amountIn);

        // 获取报价
        uint256 quotedOut = _quote(amountIn, path);
        require(quotedOut > 0, "no liquidity");

        // 计算最小接收数量
        uint256 minOut = _amountOutMin(quotedOut, slippageBps);
        // 执行兑换
        amountOut = _swap(tokenIn, tokenOut, amountIn, minOut, to, deadline);

        // 触发兑换事件
        emit SwapEvent(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    /**
     * @dev 添加流动性
     * @notice 只能由合约所有者调用
     * @param p 添加流动性的参数
     */
    function addLiquidity(
        LiquidityParams memory p
    ) external onlyOwner nonReentrant {
        // 检查输入参数
        require(
            p.tokenA != address(0) &&
                p.tokenB != address(0) &&
                p.to != address(0),
            "zero address"
        );

        // 从所有者地址转移代币到合约
        IERC20(p.tokenA).safeTransferFrom(owner(), address(this), p.amountA);
        IERC20(p.tokenB).safeTransferFrom(owner(), address(this), p.amountB);

        // 确保代币已授权给路由器
        _approveIfNeeded(p.tokenA, p.amountA);
        _approveIfNeeded(p.tokenB, p.amountB);

        // 处理截止时间
        uint256 finalDeadline = p.deadline == 0
            ? block.timestamp + 300  // 默认 5 分钟
            : p.deadline;

        (bool success, bytes memory returnData) = uniswapV2Router.call(
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
        require(success && returnData.length > 0, "addLiquidity failed");

        (uint256 amountAActual, uint256 amountBActual, uint256 liquidity) = abi
            .decode(returnData, (uint256, uint256, uint256));

        // 触发添加流动性事件
        emit LiquidityAdded(
            p.tokenA,
            p.tokenB,
            p.amountA,
            p.amountB,
            amountAActual,
            amountBActual,
            liquidity,
            p.to
        );
    }

    /**
     * @dev 移除流动性
     * @notice 只能由合约所有者调用
     * @param lpToken 流动性代币地址
     * @param tokenA 代币A地址
     * @param tokenB 代币B地址
     * @param liquidity 移除的流动性数量
     * @param amountAMin 代币A最小数量（防止滑点）
     * @param amountBMin 代币B最小数量（防止滑点）
     * @param to 接收地址
     * @param deadline 交易截止时间
     */
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
        // 检查输入参数
        require(lpToken != address(0) && to != address(0), "zero address");
        require(tokenA != address(0) && tokenB != address(0), "zero address");
        require(
            liquidity > 0,
            "the amount of liquidity must be greater than zero."
        );

        // 检查合约是否有足够的流动性代币
        require(
            IERC20(lpToken).balanceOf(address(this)) >= liquidity,
            "insufficient LP balance"
        );

        // 验证交易对是否存在，且流动性代币是否匹配
        address pair = _getPair(tokenA, tokenB);
        require(pair != address(0), "Pair not exist");
        require(pair == lpToken, "LP token mismatch");

        uint256 allowance = IERC20(lpToken).allowance(
            address(this),
            uniswapV2Router
        );
        if (allowance < liquidity) {
            IERC20(lpToken).forceApprove(uniswapV2Router, type(uint256).max);
        }

        // 处理截止时间
        uint256 finalDeadline = deadline == 0
            ? block.timestamp + 300  // 默认 5 分钟
            : deadline;

        // 调用路由器移除流动性
        (bool success, bytes memory returnData) = uniswapV2Router.call(
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
        require(success && returnData.length > 0, "removeLiquidity failed");

        (uint256 amountA, uint256 amountB) = abi.decode(
            returnData,
            (uint256, uint256)
        );

        // 触发移除流动性事件
        emit LiquidityRemoved(
            lpToken,
            liquidity,
            amountA,
            amountB,
            tokenA,
            tokenB,
            to
        );
    }

    /**
     * @dev 提取合约中的代币
     * @notice 只能由合约所有者调用
     * @param tokens 要提取的代币地址列表
     * @param to 接收地址
     */
    function withdraw(
        address[] calldata tokens,
        address to
    ) external onlyOwner {
        require(to != address(0), "to = zero");

        // 遍历提取每个代币
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 balance = IERC20(tokens[i]).balanceOf(address(this));
            if (balance > 0) {
                IERC20(tokens[i]).safeTransfer(to, balance);
            }
        }
    }
}
