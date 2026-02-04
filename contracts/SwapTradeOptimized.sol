// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title SwapTradeOptimized 合约
 * @dev 一个功能强大的代币兑换和流动性管理合约，基于 Uniswap V2
 * @notice 支持自动选择最优交易路径、防价格操纵、代币税检测等高级功能
 */
contract SwapTradeOptimized is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // 核心地址变量
    address public immutable uniswapV2Router; // Uniswap V2 路由器地址
    address public immutable factory;          // Uniswap V2 工厂地址
    address public immutable bkc;              // BKC 代币地址
    address public immutable snc;              // SNC 代币地址
    address public immutable usdt;             // USDT 代币地址

    // 常量定义
    uint256 public constant MAX_SLIPPAGE_BPS = 500;     // 最大允许滑点：500 = 5%
    uint256 public constant BPS_DENOMINATOR = 10_000;   // 滑点计算分母（10000 = 100%）
    uint256 private constant MAX_ARRAY_SIZE = 100;     // 防止gas攻击的数组大小限制

    // 可配置参数
    uint256 public maxPathDeviationBps = 500;      // 路径偏差阈值（默认 5%）- 防止价格操纵
    uint256 public defaultDeadlineSeconds = 900;   // 默认交易截止时间（15 分钟）

    // 添加流动性的参数结构体
    struct LiquidityParams {
        address tokenA;      // 代币A地址
        address tokenB;      // 代币B地址
        uint256 amountA;     // 代币A数量
        uint256 amountB;     // 代币B数量
        uint256 amountAMin;  // 代币A最小数量（防止滑点）
        uint256 amountBMin;  // 代币B最小数量（防止滑点）
        address to;          // 流动性接收地址
        uint256 deadline;    // 交易截止时间
    }

    // 事件定义
    event SwapExecuted(
        address indexed user,        // 发起兑换的用户
        address indexed tokenIn,     // 输入代币
        address indexed tokenOut,    // 输出代币
        uint256 amountIn,            // 输入数量
        uint256 amountOut,           // 输出数量
        address[] path,              // 交易路径
        uint256 slippageBps,         // 滑点设置
        uint256 timestamp            // 交易时间
    );

    event LiquidityAdded(
        address indexed user,        // 发起添加的用户
        address indexed tokenA,      // 代币A
        address indexed tokenB,      // 代币B
        address lpToken,             // 流动性代币地址
        uint256 amountADesired,      // 期望的代币A数量
        uint256 amountBDesired,      // 期望的代币B数量
        uint256 amountAActual,       // 实际添加的代币A数量
        uint256 amountBActual,       // 实际添加的代币B数量
        uint256 liquidity,           // 获得的流动性数量
        address to,                  // 流动性接收地址
        uint256 timestamp            // 交易时间
    );

    event LiquidityRemoved(
        address indexed user,        // 发起移除的用户
        address indexed lpToken,     // 流动性代币
        address indexed tokenA,      // 代币A
        address tokenB,              // 代币B
        uint256 liquidity,           // 移除的流动性数量
        uint256 amountA,             // 获得的代币A数量
        uint256 amountB,             // 获得的代币B数量
        address to,                  // 接收地址
        uint256 timestamp            // 交易时间
    );

    event LiquidityRefund(
        address indexed user,        // 退款接收用户
        address indexed tokenA,      // 代币A
        uint256 refundA,             // 代币A退款数量
        address indexed tokenB,      // 代币B
        uint256 refundB              // 代币B退款数量
    );

    event HighPriceImpact(
        address indexed user,        // 交易用户
        address indexed tokenIn,     // 输入代币
        address indexed tokenOut,    // 输出代币
        uint256 amountIn,            // 输入数量
        uint256 priceImpactBps       // 价格影响（基点）
    );

    event PathSelected(
        address indexed user,        // 交易用户
        address[] path,              // 选择的交易路径
        uint256 expectedOutput,      // 预期输出数量
        string pathType              // 路径类型（direct 或 via_usdt）
    );

    event TokenTaxDetected(
        address indexed token,       // 检测到税的代币
        uint256 reportedAmount,      // 报告的数量
        uint256 actualAmount         // 实际到账数量
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
        // 检查地址是否有效
        require(
            _uniswapV2Router != address(0) &&
                _bkc != address(0) &&
                _snc != address(0) &&
                _usdt != address(0),
            "zero address"
        );

        // 初始化核心地址
        uniswapV2Router = _uniswapV2Router;

        // 从路由器获取工厂地址
        (bool success, bytes memory data) = uniswapV2Router.staticcall(
            abi.encodeWithSignature("factory()")
        );
        require(success && data.length > 0, "factory() failed");
        factory = abi.decode(data, (address));

        // 初始化代币地址
        bkc = _bkc;
        snc = _snc;
        usdt = _usdt;
    }

    // ============ 配置管理函数 ============

    /**
     * @dev 设置最大路径偏差阈值
     * @param _newDeviationBps 新的偏差阈值（基点）
     */
    function setMaxPathDeviation(uint256 _newDeviationBps) external onlyOwner {
        require(_newDeviationBps <= 2000, "Deviation too high"); // 最多 20%
        maxPathDeviationBps = _newDeviationBps;
    }

    /**
     * @dev 设置默认交易截止时间
     * @param _seconds 新的默认截止时间（秒）
     */
    function setDefaultDeadline(uint256 _seconds) external onlyOwner {
        require(_seconds >= 60 && _seconds <= 3600, "Invalid deadline"); // 1分钟 - 1小时
        defaultDeadlineSeconds = _seconds;
    }

    // ============ 内部辅助函数 ============

    /**
     * @dev 智能授权函数
     * @notice 只有当当前授权不足时才进行授权
     * @param token 代币地址
     * @param amount 授权数量
     */
    function _approveIfNeeded(address token, uint256 amount) internal {
        if (token == address(0)) return;
        uint256 allowance = IERC20(token).allowance(address(this), uniswapV2Router);
        if (allowance >= amount) return;
        IERC20(token).forceApprove(uniswapV2Router, type(uint256).max);
    }

    /**
     * @dev 获取交易对地址
     * @param tokenA 代币A地址
     * @param tokenB 代币B地址
     * @return pair 交易对合约地址
     */
    function _getPair(address tokenA, address tokenB) internal view returns (address pair) {
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

            // 检查价格偏差，防止价格操纵
            _validatePriceDeviation(directOut, usdtOut);

            // 选择输出更大的路径
            if (usdtOut > directOut) {
                path = usdtPath;
            } else {
                path = directPath;
            }
        }
    }

    /**
     * @dev 验证价格偏差
     * @notice 防止价格操纵，确保两条路径的价格差异在合理范围内
     * @param directOut 直接路径的输出数量
     * @param usdtOut USDT中转路径的输出数量
     */
    function _validatePriceDeviation(uint256 directOut, uint256 usdtOut) internal view {
        if (directOut == 0 || usdtOut == 0) return;

        // 计算价格偏差
        uint256 larger = directOut > usdtOut ? directOut : usdtOut;
        uint256 smaller = directOut > usdtOut ? usdtOut : directOut;
        uint256 deviationBps = ((larger - smaller) * BPS_DENOMINATOR) / smaller;

        // 检查偏差是否在允许范围内
        require(
            deviationBps <= maxPathDeviationBps,
            "Price deviation too high, possible manipulation"
        );
    }

    /**
     * @dev 链上报价
     * @param amountIn 输入代币数量
     * @param path 交易路径
     * @return amountOut 预计输出代币数量
     */
    function _quote(uint256 amountIn, address[] memory path) internal view returns (uint256 amountOut) {
        (bool ok, bytes memory data) = uniswapV2Router.staticcall(
            abi.encodeWithSignature("getAmountsOut(uint256,address[])", amountIn, path)
        );
        require(ok && data.length > 0, "quote failed");
        uint256[] memory amounts = abi.decode(data, (uint256[]));
        amountOut = amounts[amounts.length - 1];
    }

    /**
     * @dev 安全报价（失败时返回 0）
     * @param amountIn 输入代币数量
     * @param path 交易路径
     * @return amountOut 预计输出代币数量，失败时返回 0
     */
    function _quoteSafe(uint256 amountIn, address[] memory path) internal view returns (uint256 amountOut) {
        (bool ok, bytes memory data) = uniswapV2Router.staticcall(
            abi.encodeWithSignature("getAmountsOut(uint256,address[])", amountIn, path)
        );
        if (!ok || data.length == 0) return 0;
        uint256[] memory amounts = abi.decode(data, (uint256[]));
        amountOut = amounts[amounts.length - 1];
    }

    /**
     * @dev 根据滑点计算最小接收数量
     * @param amountOut 预计输出数量
     * @param slippageBps 滑点（单位：基点，100 = 1%）
     * @return 考虑滑点后的最小接收数量
     */
    function _amountOutMin(uint256 amountOut, uint256 slippageBps) internal pure returns (uint256) {
        return (amountOut * (BPS_DENOMINATOR - slippageBps)) / BPS_DENOMINATOR;
    }

    /**
     * @dev 代币兑换核心逻辑
     * @notice 支持自动选择最优交易路径，带余额验证和代币税检测
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

        // 记录接收前余额，用于后续验证
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(to);

        // 从用户地址转移代币到合约
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        // 确保代币已授权给路由器
        _approveIfNeeded(tokenIn, amountIn);

        // 选择最优交易路径
        address[] memory path = _bestPath(tokenIn, tokenOut, amountIn);

        // 处理截止时间
        uint256 finalDeadline = deadline == 0
            ? block.timestamp + defaultDeadlineSeconds
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

        // 解码返回数据，获取报告的输出数量
        uint256[] memory amounts = abi.decode(data, (uint256[]));
        uint256 reportedAmountOut = amounts[amounts.length - 1];

        // 验证实际到账金额
        uint256 balanceAfter = IERC20(tokenOut).balanceOf(to);
        uint256 actualReceived = balanceAfter - balanceBefore;

        // 确保实际到账金额不低于最小输出数量
        require(actualReceived >= amountOutMin, "Insufficient output amount received");

        // 检测代币税
        if (actualReceived < reportedAmountOut) {
            emit TokenTaxDetected(tokenOut, reportedAmountOut, actualReceived);
        }

        // 返回实际到账金额
        amountOut = actualReceived;
    }

    // ============ 外部接口 ============

    /**
     * @dev 查询报价和交易路径
     * @param tokenIn 输入代币地址
     * @param tokenOut 输出代币地址
     * @param amountIn 输入代币数量
     * @return amountOut 预计输出数量
     * @return path 最优交易路径
     */
    function quote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 amountOut, address[] memory path) {
        path = _bestPath(tokenIn, tokenOut, amountIn);
        amountOut = _quote(amountIn, path);
    }

    /**
     * @dev 代币兑换
     * @notice 自动选择最优交易路径，支持设置滑点，带完整的安全检查
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

        // 获取最佳交易路径和报价
        address[] memory path = _bestPath(tokenIn, tokenOut, amountIn);
        uint256 quotedOut = _quote(amountIn, path);
        require(quotedOut > 0, "no liquidity");

        // 触发路径选择事件
        string memory pathType = path.length == 2 ? "direct" : "via_usdt";
        emit PathSelected(msg.sender, path, quotedOut, pathType);

        // 计算最小接收数量
        uint256 minOut = _amountOutMin(quotedOut, slippageBps);
        // 执行兑换
        amountOut = _swap(tokenIn, tokenOut, amountIn, minOut, to, deadline);

        // 触发兑换事件
        emit SwapExecuted(
            msg.sender,
            tokenIn,
            tokenOut,
            amountIn,
            amountOut,
            path,
            slippageBps,
            block.timestamp
        );
    }

    /**
     * @dev 添加流动性
     * @notice 支持自动退还剩余代币，带完整的安全检查
     * @param p 添加流动性的参数
     */
    function addLiquidity(LiquidityParams memory p) external nonReentrant {
        // 检查输入参数
        require(
            p.tokenA != address(0) && p.tokenB != address(0) && p.to != address(0),
            "zero address"
        );

        address sender = msg.sender;
        // 获取交易对地址
        address lpToken = _getPair(p.tokenA, p.tokenB);
        require(lpToken != address(0), "Pair does not exist");

        // 记录转账前余额，用于后续计算退款
        uint256 balanceA_before = IERC20(p.tokenA).balanceOf(address(this));
        uint256 balanceB_before = IERC20(p.tokenB).balanceOf(address(this));

        // 从用户地址转移代币到合约
        IERC20(p.tokenA).safeTransferFrom(sender, address(this), p.amountA);
        IERC20(p.tokenB).safeTransferFrom(sender, address(this), p.amountB);

        // 确保代币已授权给路由器
        _approveIfNeeded(p.tokenA, p.amountA);
        _approveIfNeeded(p.tokenB, p.amountB);

        // 处理截止时间
        uint256 finalDeadline = p.deadline == 0
            ? block.timestamp + defaultDeadlineSeconds
            : p.deadline;

        // 调用路由器添加流动性
        (bool success, bytes memory returnData) = uniswapV2Router.call(
            abi.encodeWithSignature(
                "addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256)",
                p.tokenA, p.tokenB, p.amountA, p.amountB,
                p.amountAMin, p.amountBMin, p.to, finalDeadline
            )
        );
        require(success && returnData.length > 0, "addLiquidity failed");

        // 解码返回数据
        (uint256 amountAActual, uint256 amountBActual, uint256 liquidity) = abi.decode(
            returnData,
            (uint256, uint256, uint256)
        );

        // 计算并退还剩余代币
        uint256 balanceA_after = IERC20(p.tokenA).balanceOf(address(this));
        uint256 balanceB_after = IERC20(p.tokenB).balanceOf(address(this));

        uint256 refundA = balanceA_after - balanceA_before;
        uint256 refundB = balanceB_after - balanceB_before;

        // 退还剩余代币
        if (refundA > 0) IERC20(p.tokenA).safeTransfer(sender, refundA);
        if (refundB > 0) IERC20(p.tokenB).safeTransfer(sender, refundB);

        // 触发添加流动性事件
        emit LiquidityAdded(
            sender, p.tokenA, p.tokenB, lpToken,
            p.amountA, p.amountB, amountAActual, amountBActual,
            liquidity, p.to, block.timestamp
        );

        // 触发退款事件
        if (refundA > 0 || refundB > 0) {
            emit LiquidityRefund(sender, p.tokenA, refundA, p.tokenB, refundB);
        }
    }

    /**
     * @dev 移除流动性
     * @notice 从用户地址转移流动性代币，然后将其移除
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
    ) external nonReentrant {
        // 检查输入参数
        require(lpToken != address(0) && to != address(0), "zero address");
        require(tokenA != address(0) && tokenB != address(0), "zero address");
        require(liquidity > 0, "liquidity = 0");

        // 从用户地址转移流动性代币到合约
        IERC20(lpToken).safeTransferFrom(msg.sender, address(this), liquidity);

        // 验证交易对是否存在，且流动性代币是否匹配
        address pair = _getPair(tokenA, tokenB);
        require(pair != address(0) && pair == lpToken, "Invalid LP token");

        // 确保流动性代币已授权给路由器
        _approveIfNeeded(lpToken, liquidity);

        // 处理截止时间
        uint256 finalDeadline = deadline == 0
            ? block.timestamp + defaultDeadlineSeconds
            : deadline;

        // 调用路由器移除流动性
        (bool success, bytes memory returnData) = uniswapV2Router.call(
            abi.encodeWithSignature(
                "removeLiquidity(address,address,uint256,uint256,uint256,address,uint256)",
                tokenA, tokenB, liquidity, amountAMin, amountBMin, to, finalDeadline
            )
        );
        require(success && returnData.length > 0, "removeLiquidity failed");

        // 解码返回数据
        (uint256 amountA, uint256 amountB) = abi.decode(returnData, (uint256, uint256));

        // 触发移除流动性事件
        emit LiquidityRemoved(
            msg.sender, lpToken, tokenA, tokenB,
            liquidity, amountA, amountB, to, block.timestamp
        );
    }

    /**
     * @dev 提取合约中的代币
     * @notice 只能由合约所有者调用
     * @param tokens 要提取的代币地址列表
     * @param to 接收地址
     */
    function withdraw(address[] calldata tokens, address to) external onlyOwner {
        require(to != address(0), "to = zero");
        uint256 len = tokens.length;
        require(len > 0 && len <= MAX_ARRAY_SIZE, "Invalid array length");

        // 遍历提取每个代币
        for (uint256 i = 0; i < len; ) {
            require(tokens[i] != address(0), "zero address");
            uint256 balance = IERC20(tokens[i]).balanceOf(address(this));
            if (balance > 0) {
                IERC20(tokens[i]).safeTransfer(to, balance);
                emit Withdraw(tokens[i], to, balance);
            }
            unchecked { ++i; }
        }
    }

    /**
     * @dev 提取ETH
     * @notice 只能由合约所有者调用，带重入防护
     * @param to ETH接收地址
     */
    function withdrawETH(address payable to) external onlyOwner nonReentrant {
        require(to != address(0), "zero address");
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");
        to.transfer(balance);
    }

    // 接收ETH的回调函数
    receive() external payable {}

    /**
     * @dev 获取用户的代币余额
     * @param token 代币地址
     * @return 用户的代币余额
     */
    function getAccountBalance(address token) external view returns(uint256) {
        require(token != address(0), "zero address");
        return IERC20(token).balanceOf(msg.sender);
    }
}