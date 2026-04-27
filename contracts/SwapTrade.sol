// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @dev Uniswap V2 Factory 最小接口。
 * 大白话：只用来查询两个 token 有没有交易对。
 */
interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/**
 * @dev Uniswap V2 Router 最小接口。
 * 大白话：这里只声明本合约真正会用到的方法。
 */
interface IUniswapV2Router02 {
    function factory() external view returns (address);

    function getAmountsOut(
        uint256 amountIn,
        address[] memory path
    ) external view returns (uint256[] memory amounts);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);
}

/**
 * @title SwapTrade
 *
 * @notice 基于 Uniswap V2 Router 的 ERC20 换币和流动性管理合约。
 *
 * 大白话说明：
 * 1. 用户可以通过本合约换币。
 * 2. 可以自动比较“直连路径”和“单个中转 token 路径”。
 * 3. 用户也可以手动指定 path，更适合前端或大额交易。
 * 4. 用户可以添加、移除流动性。
 * 5. 添加流动性时，多余没用完的 token 会自动退回。
 * 6. owner 可以维护 token 白名单。
 * 7. Router 可以迁移，但必须先暂停，并且排队等待 2 天后才能执行。
 *
 * 重要安全提醒：
 * - 自动路径只比较两种路径：
 *   A. tokenIn -> tokenOut
 *   B. tokenIn -> middleToken -> tokenOut
 *   它不会搜索多个白名单 token 组成的复杂多跳路径。
 *
 * - 自动路径里的 getAmountsOut 会根据当前池子储备和当前输入数量计算输出，
 *   所以它会反映当前这一笔交易的价格影响；
 *   但它仍然只是当前区块状态的快照，不能防止后续区块价格变化或 MEV。
 *
 * - 大额交易更推荐使用 swapWithPath，由前端或用户自己传 path 和 amountOutMin。
 *
 * - 本合约不支持 fee-on-transfer、扣税币、反射币等非标准 ERC20。
 *
 * - owner 权限依然重要，正式上线建议 owner 使用多签或 Timelock。
 *
 * - 本版本没有 rescueKnownTokens。
 *   也就是说，owner 不能直接提走 BKC/SNC/USDT，也不能提走任何曾经加入过白名单的 token。
 *   这样信任假设更清晰，但代价是：如果有人误转项目 token 到本合约，这些 token 可能无法救回。
 */
contract SwapTrade is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ========== 初始项目 token ==========

    // 大白话：部署时传入的 BKC 地址，保留给前端读取。
    address public immutable bkc;

    // 大白话：部署时传入的 SNC 地址，保留给前端读取。
    address public immutable snc;

    // 大白话：部署时传入的 USDT 地址，默认作为中转 token。
    address public immutable usdt;

    // ========== Router / Factory ==========

    // 大白话：当前使用的 Uniswap V2 Router。
    address public uniswapV2Router;

    // 大白话：当前 Router 对应的 Factory。
    address public factory;

    // 大白话：自动路径优选时使用的中转 token，默认是 USDT。
    address public middleToken;

    // ========== Router 延迟更新 ==========

    // 大白话：Router 更新需要等待 2 天，给用户和前端足够观察时间。
    uint256 public constant ROUTER_UPDATE_DELAY = 2 days;

    // 大白话：正在等待生效的新 Router。
    // 如果这里不是 0，说明已经有一个 Router 更新在排队。
    address public pendingRouter;

    // 大白话：排队时记录下来的 Factory。
    // 执行 Router 更新时，会重新读取 Router.factory()，并要求它和 pendingFactory 一致。
    address public pendingFactory;

    // 大白话：到了这个时间点以后，才可以执行 Router 更新。
    uint256 public pendingRouterExecuteAfter;

    // ========== Token 白名单 ==========

    // 大白话：当前允许参与 swap、加池、移除池的 token。
    mapping(address => bool) public supportedToken;

    // 大白话：曾经加入过白名单的 token，或者项目相关 LP token。
    // 作用：防止 owner 先把项目 token 移出白名单，再通过普通误转提现提走。
    mapping(address => bool) public everSupportedToken;

    // ========== 常量 ==========

    // 大白话：自动滑点最小 0.01%。
    // 原因：如果滑点传 0，amountOutMin 会等于当前报价，价格稍微变一点就容易失败。
    uint256 public constant MIN_SLIPPAGE_BPS = 1;

    // 大白话：自动滑点最大 5%。100 = 1%，500 = 5%。
    uint256 public constant MAX_SLIPPAGE_BPS = 500;

    // 大白话：基点分母。10000 = 100%。
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // 大白话：用户不传 deadline 时，默认 30 分钟后过期。
    uint256 public constant DEFAULT_DEADLINE_SECONDS = 1800;

    // 大白话：批量提现最多 20 个 token，降低一次交易 gas 过大的风险。
    uint256 private constant MAX_WITHDRAW_ARRAY_SIZE = 20;

    // 大白话：用户手动传 path 时，最多允许 5 个 token。
    uint256 public constant MAX_PATH_SIZE = 5;

    /**
     * @dev 添加流动性的参数。
     * 大白话：把一堆参数打包，避免函数参数太长。
     */
    struct LiquidityParams {
        address tokenA;       // tokenA 地址
        address tokenB;       // tokenB 地址
        uint256 amountA;      // 用户愿意提供的 tokenA 数量
        uint256 amountB;      // 用户愿意提供的 tokenB 数量
        uint256 amountAMin;   // 最少必须实际加入多少 tokenA
        uint256 amountBMin;   // 最少必须实际加入多少 tokenB
        address to;           // LP token 给谁
        uint256 deadline;     // 过期时间，传 0 则默认 30 分钟
    }

    // ========== 事件 ==========

    event LiquidityAdded(
        address indexed tokenA,
        address indexed tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAActual,
        uint256 amountBActual,
        uint256 liquidity,
        address indexed to
    );

    event LiquidityRemoved(
        address indexed lpToken,
        uint256 liquidity,
        uint256 amountA,
        uint256 amountB,
        address indexed tokenA,
        address indexed tokenB,
        address to
    );

    event SwapEvent(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 amountOutMin,
        uint256 quotedOut,
        address[] path,
        uint256 slippageBps,
        bool autoSlippage,
        uint256 timestamp
    );

    event Withdraw(address indexed token, address indexed to, uint256 amount);

    event Refund(address indexed token, address indexed to, uint256 amount);

    event TokenSupportUpdated(address indexed token, bool supported);

    event KnownAssetMarked(address indexed token);

    event RouterUpdateScheduled(
        address indexed oldRouter,
        address indexed newRouter,
        address indexed newFactory,
        uint256 executeAfter
    );

    event RouterUpdateCancelled(address indexed pendingRouter);

    event RouterUpdated(
        address indexed oldRouter,
        address indexed newRouter,
        address indexed oldFactory,
        address newFactory
    );

    event MiddleTokenUpdated(address indexed oldMiddleToken, address indexed newMiddleToken);

    /**
     * @dev 构造函数。
     *
     * 大白话：
     * 部署时传入 BKC、SNC、USDT 和 Router。
     * 初始白名单会自动加入 BKC、SNC、USDT。
     * 默认中转 token 是 USDT。
     */
    constructor(
        address _bkc,
        address _snc,
        address _usdt,
        address _uniswapV2Router
    ) Ownable(msg.sender) {
        require(_bkc != address(0), "bkc zero");
        require(_snc != address(0), "snc zero");
        require(_usdt != address(0), "usdt zero");
        require(_uniswapV2Router != address(0), "router zero");

        require(_bkc != _snc && _bkc != _usdt && _snc != _usdt, "duplicate token");

        require(_bkc.code.length > 0, "bkc no code");
        require(_snc.code.length > 0, "snc no code");
        require(_usdt.code.length > 0, "usdt no code");

        bkc = _bkc;
        snc = _snc;
        usdt = _usdt;

        _setSupportedTokenInternal(_bkc, true);
        _setSupportedTokenInternal(_snc, true);
        _setSupportedTokenInternal(_usdt, true);

        middleToken = _usdt;

        _setRouterInternal(_uniswapV2Router);
    }

    // ========== owner 管理函数 ==========

    /**
     * @dev 暂停主要业务。
     * 大白话：暂停后不能换币、不能加池、不能移除池。
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev 恢复主要业务。
     * 大白话：恢复后可以继续换币、加池、移除池。
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev 排队更新 Router。
     *
     * 大白话：
     * Router 更新是高风险操作。
     * 这里不能立刻换，而是先排队，等 ROUTER_UPDATE_DELAY 之后才能真正执行。
     *
     * 注意：
     * 1. 必须先暂停合约，才能排队更新 Router。
     * 2. 如果已经有 Router 更新在排队，不能直接覆盖。
     * 3. 要改新的 Router，必须先取消旧的 pending Router。
     * 4. 这里加 nonReentrant，避免恶意 Router 在 factory() 回调里制造重入干扰。
     */
    function scheduleRouterUpdate(address newRouter) external onlyOwner whenPaused nonReentrant {
        require(newRouter != address(0), "router zero");
        require(newRouter != uniswapV2Router, "same router");
        require(pendingRouter == address(0), "pending router exists");

        address newFactory = _validateRouter(newRouter);

        pendingRouter = newRouter;
        pendingFactory = newFactory;
        pendingRouterExecuteAfter = block.timestamp + ROUTER_UPDATE_DELAY;

        emit RouterUpdateScheduled(
            uniswapV2Router,
            newRouter,
            newFactory,
            pendingRouterExecuteAfter
        );
    }

    /**
     * @dev 取消正在排队的 Router 更新。
     *
     * 大白话：
     * 如果发现新 Router 填错了，或者临时不想改了，可以取消。
     */
    function cancelRouterUpdate() external onlyOwner whenPaused {
        address oldPendingRouter = pendingRouter;

        require(oldPendingRouter != address(0), "no pending router");

        pendingRouter = address(0);
        pendingFactory = address(0);
        pendingRouterExecuteAfter = 0;

        emit RouterUpdateCancelled(oldPendingRouter);
    }

    /**
     * @dev 执行 Router 更新。
     *
     * 大白话：
     * 必须满足：
     * 1. 合约处于暂停状态。
     * 2. 已经提前 schedule。
     * 3. 等待时间已经到。
     * 4. 执行时 Router 返回的 factory，必须和排队时记录的 pendingFactory 一致。
     * 5. 真正执行的 Router 地址就是 pendingRouter，不会换成其他地址。
     */
    function executeRouterUpdate() external onlyOwner whenPaused nonReentrant {
        address newRouter = pendingRouter;
        address expectedFactory = pendingFactory;

        require(newRouter != address(0), "no pending router");
        require(expectedFactory != address(0), "no pending factory");
        require(block.timestamp >= pendingRouterExecuteAfter, "router delay");

        address oldRouter = uniswapV2Router;
        address oldFactory = factory;

        address actualFactory = _validateRouter(newRouter);

        require(actualFactory == expectedFactory, "factory changed");

        pendingRouter = address(0);
        pendingFactory = address(0);
        pendingRouterExecuteAfter = 0;

        uniswapV2Router = newRouter;
        factory = actualFactory;

        emit RouterUpdated(oldRouter, newRouter, oldFactory, actualFactory);
    }

    /**
     * @dev 更新自动路径的中转 token。
     *
     * 大白话：
     * 比如原来用 USDT 中转，以后想改成 USDC，可以改。
     * 但新的中转 token 必须已经在白名单里。
     *
     * 注意：
     * 自动路径只比较 direct 和 middleToken 中转，不会搜索所有白名单 token。
     */
    function setMiddleToken(address newMiddleToken) external onlyOwner whenPaused {
        require(newMiddleToken != address(0), "middle zero");
        require(newMiddleToken != middleToken, "same middle");
        require(supportedToken[newMiddleToken], "middle unsupported");

        address oldMiddleToken = middleToken;
        middleToken = newMiddleToken;

        emit MiddleTokenUpdated(oldMiddleToken, newMiddleToken);
    }

    /**
     * @dev 管理 token 白名单。
     *
     * 大白话：
     * - 添加 token 后，这个 token 可以用于 swap、加池、移除池。
     * - 移除 token 后，这个 token 不能再用于新交易。
     * - 必须暂停后才能改白名单，避免线上交易中途规则变化。
     */
    function setSupportedToken(address token, bool supported) external onlyOwner whenPaused {
        require(token != address(0), "token zero");

        if (!supported) {
            require(token != middleToken, "middle token");
        }

        _setSupportedTokenInternal(token, supported);
    }

    /**
     * @dev 手动清理某个 token 对某个 Router 的授权。
     *
     * 大白话：
     * 正常情况下，本合约每次操作后都会清掉授权。
     * 这个函数只是预留给极端情况，比如迁移 Router 后想手动清理旧授权。
     */
    function clearRouterApproval(address token, address router) external onlyOwner nonReentrant {
        require(token != address(0), "token zero");
        require(router != address(0), "router zero");

        IERC20(token).forceApprove(router, 0);
    }

    // ========== 查询函数 ==========

    /**
     * @dev 查询两个 token 的交易对。
     * 大白话：如果没有 pair，返回 address(0)。
     */
    function getPair(address tokenA, address tokenB) external view returns (address) {
        require(tokenA != address(0) && tokenB != address(0), "zero address");
        require(tokenA != tokenB, "same token");

        return _getPair(tokenA, tokenB);
    }

    /**
     * @dev 自动路径报价。
     *
     * 大白话：
     * 合约只比较两种路径：
     * 1. tokenIn -> tokenOut
     * 2. tokenIn -> middleToken -> tokenOut
     *
     * 它不会自动搜索更多 token 组成的复杂多跳路径。
     * 如果想走复杂路径，请使用 quotePath 和 swapWithPath。
     */
    function quote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 amountOut, address[] memory path) {
        _requireSupportedPair(tokenIn, tokenOut);
        require(amountIn > 0, "amountIn = 0");

        (amountOut, path) = _bestQuoteAndPath(tokenIn, tokenOut, amountIn);
    }

    /**
     * @dev 指定 path 报价。
     *
     * 大白话：
     * 前端如果自己决定路径，可以用这个函数查指定路径能换多少。
     */
    function quotePath(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256 amountOut) {
        require(amountIn > 0, "amountIn = 0");

        address[] memory pathMem = _copyPath(path);

        _requireSupportedPath(pathMem);

        amountOut = _quoteStrict(amountIn, pathMem);
    }

    /**
     * @dev 查询账户余额。
     * 大白话：方便前端展示某个账户的某个 token 余额。
     */
    function getAccountBalance(address token, address account) external view returns (uint256) {
        require(token != address(0) && account != address(0), "zero address");

        return IERC20(token).balanceOf(account);
    }

    // ========== 换币函数 ==========

    /**
     * @dev 自动滑点版本换币。
     *
     * 大白话：
     * 用户只传滑点，比如 100 = 1%。
     * 合约会按当前区块状态报价，然后算 amountOutMin。
     *
     * 风险提醒：
     * 这个函数方便，但大额交易不建议用。
     * 因为攻击者可能影响池子价格，让你的“当前报价”本身就变差。
     * 大额交易更推荐使用 swapWithMinOut 或 swapWithPath。
     */
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 slippageBps,
        address to,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        _requireSupportedPair(tokenIn, tokenOut);
        _requireRecipient(to);

        require(amountIn > 0, "amountIn = 0");
        require(slippageBps >= MIN_SLIPPAGE_BPS, "slippage too small");
        require(slippageBps <= MAX_SLIPPAGE_BPS, "slippage too large");

        (uint256 quotedOut, address[] memory path) = _bestQuoteAndPath(tokenIn, tokenOut, amountIn);

        uint256 amountOutMin = _amountOutMin(quotedOut, slippageBps);
        require(amountOutMin > 0, "minOut = 0");

        uint256 finalDeadline = _finalDeadline(deadline);

        amountOut = _swapUsingPath(
            msg.sender,
            amountIn,
            amountOutMin,
            to,
            finalDeadline,
            path
        );

        emit SwapEvent(
            msg.sender,
            tokenIn,
            tokenOut,
            amountIn,
            amountOut,
            amountOutMin,
            quotedOut,
            path,
            slippageBps,
            true,
            block.timestamp
        );
    }

    /**
     * @dev 自动选路径，但用户自己传最小输出数量。
     *
     * 大白话：
     * 这个比 swap 更推荐。
     * 前端先报价，用户确认最低能接受多少，然后传 amountOutMin。
     *
     * 注意：
     * 这里不提前 require(quotedOut >= amountOutMin)。
     * 最终是否满足 amountOutMin 交给 Router 自己判断。
     */
    function swapWithMinOut(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        _requireSupportedPair(tokenIn, tokenOut);
        _requireRecipient(to);

        require(amountIn > 0, "amountIn = 0");
        require(amountOutMin > 0, "minOut = 0");

        (uint256 quotedOut, address[] memory path) = _bestQuoteAndPath(tokenIn, tokenOut, amountIn);

        uint256 finalDeadline = _finalDeadline(deadline);

        amountOut = _swapUsingPath(
            msg.sender,
            amountIn,
            amountOutMin,
            to,
            finalDeadline,
            path
        );

        emit SwapEvent(
            msg.sender,
            tokenIn,
            tokenOut,
            amountIn,
            amountOut,
            amountOutMin,
            quotedOut,
            path,
            0,
            false,
            block.timestamp
        );
    }

    /**
     * @dev 用户手动指定 path 的换币函数。
     *
     * 大白话：
     * 这是给前端或高级用户用的。
     * 你不想让合约自动决定路径，就自己传 path。
     *
     * 例如：
     * path = [BKC, USDT, SNC]
     */
    function swapWithPath(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        _requireRecipient(to);

        require(amountIn > 0, "amountIn = 0");
        require(amountOutMin > 0, "minOut = 0");

        address[] memory pathMem = _copyPath(path);

        _requireSupportedPath(pathMem);

        uint256 finalDeadline = _finalDeadline(deadline);

        amountOut = _swapUsingPath(
            msg.sender,
            amountIn,
            amountOutMin,
            to,
            finalDeadline,
            pathMem
        );

        emit SwapEvent(
            msg.sender,
            pathMem[0],
            pathMem[pathMem.length - 1],
            amountIn,
            amountOut,
            amountOutMin,
            0,
            pathMem,
            0,
            false,
            block.timestamp
        );
    }

    // ========== 流动性函数 ==========

    /**
     * @dev 添加流动性。
     *
     * 大白话：
     * 用户先授权本合约。
     * 本合约把 token 拉进来，再授权给 Router。
     * Router 实际用多少就用多少。
     * 多余的自动退回用户。
     *
     * 重要：
     * amountAMin 和 amountBMin 不能是 0。
     * 如果传 0，等于完全不做滑点保护。
     */
    function addLiquidity(
        LiquidityParams calldata p
    )
        external
        nonReentrant
        whenNotPaused
        returns (uint256 amountAActual, uint256 amountBActual, uint256 liquidity)
    {
        _requireSupportedPair(p.tokenA, p.tokenB);
        _requireRecipient(p.to);

        require(p.amountA > 0 && p.amountB > 0, "amount zero");
        require(p.amountAMin > 0 && p.amountBMin > 0, "min zero");
        require(p.amountAMin <= p.amountA, "bad amountAMin");
        require(p.amountBMin <= p.amountB, "bad amountBMin");

        uint256 finalDeadline = _finalDeadline(p.deadline);

        _pullExactToken(p.tokenA, msg.sender, p.amountA);
        _pullExactToken(p.tokenB, msg.sender, p.amountB);

        _approveRouter(p.tokenA, p.amountA);
        _approveRouter(p.tokenB, p.amountB);

        (amountAActual, amountBActual, liquidity) = IUniswapV2Router02(uniswapV2Router).addLiquidity(
            p.tokenA,
            p.tokenB,
            p.amountA,
            p.amountB,
            p.amountAMin,
            p.amountBMin,
            p.to,
            finalDeadline
        );

        _clearRouterApproval(p.tokenA);
        _clearRouterApproval(p.tokenB);

        require(liquidity > 0, "no liquidity");

        // 大白话：把这个交易对 LP 也标记为项目相关资产。
        // 这样 owner 不能通过 withdrawUnsupportedTokens 把项目 LP 当成“无关误转 token”提走。
        address pair = _getPair(p.tokenA, p.tokenB);
        if (pair != address(0)) {
            _markEverSupported(pair);
        }

        if (p.amountA > amountAActual) {
            _refund(p.tokenA, msg.sender, p.amountA - amountAActual);
        }

        if (p.amountB > amountBActual) {
            _refund(p.tokenB, msg.sender, p.amountB - amountBActual);
        }

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
     * @dev 移除流动性。
     *
     * 大白话：
     * 用户把 LP token 授权给本合约。
     * 本合约把 LP token 拉进来，然后通过 Router 拆回 tokenA/tokenB。
     *
     * 重要：
     * amountAMin 和 amountBMin 不能是 0。
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
    ) external nonReentrant whenNotPaused returns (uint256 amountA, uint256 amountB) {
        require(lpToken != address(0), "lp zero");
        _requireRecipient(to);

        require(liquidity > 0, "liquidity = 0");
        require(amountAMin > 0 && amountBMin > 0, "min zero");

        _requireSupportedPair(tokenA, tokenB);

        address pair = _getPair(tokenA, tokenB);
        require(pair != address(0), "pair not exist");
        require(pair == lpToken, "LP mismatch");

        // 大白话：提前检查 LP 余额，报错更清楚。
        // 即使没有这行，safeTransferFrom 也会失败；这里主要是为了更早、更明确地提示。
        require(IERC20(lpToken).balanceOf(msg.sender) >= liquidity, "LP balance insufficient");

        _markEverSupported(pair);

        uint256 finalDeadline = _finalDeadline(deadline);

        _pullExactToken(lpToken, msg.sender, liquidity);

        _approveRouter(lpToken, liquidity);

        (amountA, amountB) = IUniswapV2Router02(uniswapV2Router).removeLiquidity(
            tokenA,
            tokenB,
            liquidity,
            amountAMin,
            amountBMin,
            to,
            finalDeadline
        );

        _clearRouterApproval(lpToken);

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

    // ========== 提现函数 ==========

    /**
     * @dev 提取从未加入过白名单的误转 token。
     *
     * 大白话：
     * 这个函数只能提“完全无关的误转 token”。
     *
     * 不能提：
     * - BKC
     * - SNC
     * - USDT
     * - 任何曾经加入过白名单的 token
     * - 通过本合约用过的项目相关 LP token
     *
     * 这么设计是为了避免 owner 通过提现函数拿走项目相关 token。
     */
    function withdrawUnsupportedTokens(
        address[] calldata tokens,
        address to
    ) external onlyOwner nonReentrant {
        _requireRecipient(to);

        uint256 len = tokens.length;
        require(len > 0 && len <= MAX_WITHDRAW_ARRAY_SIZE, "bad array length");

        // 大白话：
        // 第一轮只做校验，不做转账。
        // 这样如果数组里有重复地址、0 地址、项目相关 token，会直接失败，不会先转一半。
        for (uint256 i = 0; i < len; ) {
            address token = tokens[i];

            require(token != address(0), "token zero");
            require(token.code.length > 0, "token no code");
            require(!everSupportedToken[token], "known token");

            for (uint256 j = i + 1; j < len; ) {
                require(token != tokens[j], "duplicate token");

                unchecked {
                    ++j;
                }
            }

            unchecked {
                ++i;
            }
        }

        // 大白话：
        // 第二轮才真正执行转账。
        for (uint256 i = 0; i < len; ) {
            address token = tokens[i];

            uint256 balance = IERC20(token).balanceOf(address(this));

            if (balance > 0) {
                IERC20(token).safeTransfer(to, balance);
                emit Withdraw(token, to, balance);
            }

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev 提取 ETH。
     *
     * 大白话：
     * 本合约不做 ETH 交易。
     * 这个函数只是为了提取误转进来的 ETH。
     *
     * 注意：
     * to 可以是普通钱包，也可以是合约钱包。
     * 如果目标合约不能接收 ETH，这里会自动 revert。
     */
    function withdrawETH(address payable to) external onlyOwner nonReentrant {
        _requireRecipient(to);

        uint256 amount = address(this).balance;
        require(amount > 0, "no ETH");

        (bool ok, ) = to.call{value: amount}("");
        require(ok, "ETH transfer failed");

        emit Withdraw(address(0), to, amount);
    }

    /**
     * @dev 接收 ETH。
     * 大白话：只为了兼容误转 ETH，本合约没有 ETH swap 逻辑。
     */
    receive() external payable {}

    // ========== 内部函数：校验 ==========

    /**
     * @dev 校验接收地址。
     *
     * 大白话：
     * 1. 不能是 0 地址。
     * 2. 不能是本合约地址。
     *
     * 不禁止合约地址：
     * 因为很多用户的安全钱包、多签钱包、AA 钱包都是合约地址。
     */
    function _requireRecipient(address to) internal view {
        require(to != address(0), "to zero");
        require(to != address(this), "to self");
    }

    /**
     * @dev 校验两个 token 是否可以交易。
     */
    function _requireSupportedPair(address tokenA, address tokenB) internal view {
        require(tokenA != address(0) && tokenB != address(0), "zero address");
        require(tokenA != tokenB, "same token");
        require(supportedToken[tokenA] && supportedToken[tokenB], "unsupported token");
    }

    /**
     * @dev 校验用户手动传入的 path。
     *
     * 大白话：
     * path 至少 2 个地址，最多 5 个地址。
     * path 里的每个 token 都必须在白名单里。
     * 每一跳都必须有 pair。
     * 整条路径里不能出现重复 token，比如 [A, B, A, C] 不允许。
     */
    function _requireSupportedPath(address[] memory path) internal view {
        uint256 len = path.length;

        require(len >= 2, "path too short");
        require(len <= MAX_PATH_SIZE, "path too long");

        for (uint256 i = 0; i < len; ) {
            address token = path[i];

            require(token != address(0), "path zero token");
            require(supportedToken[token], "path unsupported token");

            // 大白话：
            // 检查整条路径里不能有重复 token。
            // MAX_PATH_SIZE 只有 5，所以 O(n^2) 循环没问题。
            for (uint256 j = i + 1; j < len; ) {
                require(token != path[j], "duplicate path token");

                unchecked {
                    ++j;
                }
            }

            if (i + 1 < len) {
                require(_getPair(token, path[i + 1]) != address(0), "path pair not exist");
            }

            unchecked {
                ++i;
            }
        }
    }

    // ========== 内部函数：Router / 白名单 ==========

    /**
     * @dev 验证 Router 是否基本可用。
     *
     * 大白话：
     * Router 必须是合约地址，并且能读出 factory。
     */
    function _validateRouter(address router) internal view returns (address routerFactory) {
        require(router != address(0), "router zero");
        require(router.code.length > 0, "router no code");

        try IUniswapV2Router02(router).factory() returns (address f) {
            routerFactory = f;
        } catch {
            revert("factory failed");
        }

        require(routerFactory != address(0), "factory zero");
        require(routerFactory.code.length > 0, "factory no code");
    }

    /**
     * @dev 设置 Router。
     *
     * 大白话：
     * 内部函数，构造函数会用。
     */
    function _setRouterInternal(address newRouter) internal returns (address newFactory) {
        newFactory = _validateRouter(newRouter);

        uniswapV2Router = newRouter;
        factory = newFactory;
    }

    /**
     * @dev 设置 token 白名单。
     */
    function _setSupportedTokenInternal(address token, bool supported) internal {
        require(token != address(0), "token zero");

        if (supported) {
            require(token.code.length > 0, "token no code");
            _markEverSupported(token);
        }

        supportedToken[token] = supported;

        emit TokenSupportUpdated(token, supported);
    }

    /**
     * @dev 标记为项目相关资产。
     *
     * 大白话：
     * 被标记后，owner 不能通过 withdrawUnsupportedTokens 提走它。
     */
    function _markEverSupported(address token) internal {
        require(token != address(0), "token zero");

        if (!everSupportedToken[token]) {
            everSupportedToken[token] = true;
            emit KnownAssetMarked(token);
        }
    }

    // ========== 内部函数：路径和报价 ==========

    /**
     * @dev 查询 pair。
     */
    function _getPair(address tokenA, address tokenB) internal view returns (address pair) {
        if (tokenA == tokenB) {
            return address(0);
        }

        pair = IUniswapV2Factory(factory).getPair(tokenA, tokenB);
    }

    /**
     * @dev 自动找当前报价较好的路径。
     *
     * 大白话：
     * 只比较两种：
     * 1. tokenIn -> tokenOut
     * 2. tokenIn -> middleToken -> tokenOut
     *
     * 它不是全路径搜索。
     * 如果白名单里有 USDC、DAI、WETH 等多个 token，
     * 本函数不会自动尝试 tokenIn -> USDC -> DAI -> tokenOut 这类路径。
     */
    function _bestQuoteAndPath(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (uint256 bestOut, address[] memory bestPath) {
        uint256 directOut;
        address[] memory directPath;

        if (_getPair(tokenIn, tokenOut) != address(0)) {
            directPath = new address[](2);
            directPath[0] = tokenIn;
            directPath[1] = tokenOut;

            directOut = _quoteSafe(amountIn, directPath);
        }

        uint256 middleOut;
        address[] memory middlePath;

        address mid = middleToken;

        if (tokenIn != mid && tokenOut != mid && supportedToken[mid]) {
            bool hasInMidPair = _getPair(tokenIn, mid) != address(0);
            bool hasOutMidPair = _getPair(mid, tokenOut) != address(0);

            if (hasInMidPair && hasOutMidPair) {
                middlePath = new address[](3);
                middlePath[0] = tokenIn;
                middlePath[1] = mid;
                middlePath[2] = tokenOut;

                middleOut = _quoteSafe(amountIn, middlePath);
            }
        }

        require(directOut > 0 || middleOut > 0, "no liquidity");

        if (middleOut > directOut) {
            return (middleOut, middlePath);
        }

        return (directOut, directPath);
    }

    /**
     * @dev 严格报价，失败就 revert。
     */
    function _quoteStrict(
        uint256 amountIn,
        address[] memory path
    ) internal view returns (uint256 amountOut) {
        uint256[] memory amounts = IUniswapV2Router02(uniswapV2Router).getAmountsOut(amountIn, path);

        require(amounts.length == path.length, "bad quote result");

        amountOut = amounts[amounts.length - 1];
        require(amountOut > 0, "quote zero");
    }

    /**
     * @dev 安全报价，失败返回 0。
     *
     * 大白话：
     * 自动比较路径时使用。
     * 某条路径报价失败，不影响另一条路径。
     */
    function _quoteSafe(
        uint256 amountIn,
        address[] memory path
    ) internal view returns (uint256 amountOut) {
        try IUniswapV2Router02(uniswapV2Router).getAmountsOut(amountIn, path) returns (
            uint256[] memory amounts
        ) {
            if (amounts.length != path.length) {
                return 0;
            }

            amountOut = amounts[amounts.length - 1];
        } catch {
            return 0;
        }
    }

    /**
     * @dev 根据滑点计算最低接收数量。
     *
     * 大白话：
     * slippageBps = 100 表示 1%。
     */
    function _amountOutMin(
        uint256 quotedOut,
        uint256 slippageBps
    ) internal pure returns (uint256) {
        return (quotedOut * (BPS_DENOMINATOR - slippageBps)) / BPS_DENOMINATOR;
    }

    /**
     * @dev 处理 deadline。
     *
     * 大白话：
     * 用户传 0，就默认 30 分钟。
     * 用户传具体时间，就不能是过去时间。
     */
    function _finalDeadline(uint256 deadline) internal view returns (uint256) {
        if (deadline == 0) {
            return block.timestamp + DEFAULT_DEADLINE_SECONDS;
        }

        require(deadline >= block.timestamp, "deadline expired");

        return deadline;
    }

    /**
     * @dev 把 calldata path 复制到 memory。
     *
     * 大白话：
     * 外部函数收到的是 calldata，内部处理和事件记录用 memory 更方便。
     */
    function _copyPath(address[] calldata path) internal pure returns (address[] memory pathMem) {
        uint256 len = path.length;

        require(len >= 2, "path too short");
        require(len <= MAX_PATH_SIZE, "path too long");

        pathMem = new address[](len);

        for (uint256 i = 0; i < len; ) {
            pathMem[i] = path[i];

            unchecked {
                ++i;
            }
        }
    }

    // ========== 内部函数：执行转账 / 授权 / swap ==========

    /**
     * @dev 按 path 执行换币。
     *
     * 大白话：
     * 1. 从用户那里把 tokenIn 拉到本合约。
     * 2. 本合约授权 Router。
     * 3. Router 执行 swap。
     * 4. 清掉授权。
     */
    function _swapUsingPath(
        address payer,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline,
        address[] memory path
    ) internal returns (uint256 amountOut) {
        address tokenIn = path[0];

        _pullExactToken(tokenIn, payer, amountIn);
        _approveRouter(tokenIn, amountIn);

        uint256[] memory amounts = IUniswapV2Router02(uniswapV2Router).swapExactTokensForTokens(
            amountIn,
            amountOutMin,
            path,
            to,
            deadline
        );

        _clearRouterApproval(tokenIn);

        require(amounts.length == path.length, "bad swap result");

        amountOut = amounts[amounts.length - 1];
    }

    /**
     * @dev 从用户那里拉 token，并要求完整到账。
     *
     * 大白话：
     * 如果用户转 100，合约必须收到 100。
     * 如果只收到 99，说明这个 token 可能有手续费或扣税，本合约不支持。
     */
    function _pullExactToken(address token, address from, uint256 amount) internal {
        require(amount > 0, "amount zero");

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));

        IERC20(token).safeTransferFrom(from, address(this), amount);

        uint256 balanceAfter = IERC20(token).balanceOf(address(this));

        require(balanceAfter >= balanceBefore, "bad token balance");
        require(balanceAfter - balanceBefore == amount, "fee token unsupported");
    }

    /**
     * @dev 给 Router 授权本次需要的数量。
     *
     * 大白话：
     * 不做无限授权。
     * forceApprove 可以兼容 USDT 这类需要先清零再授权的 token。
     */
    function _approveRouter(address token, uint256 amount) internal {
        IERC20(token).forceApprove(uniswapV2Router, amount);
    }

    /**
     * @dev 清理 Router 授权。
     *
     * 大白话：
     * 这里不先读 allowance。
     * 直接清零，代码更简单。
     */
    function _clearRouterApproval(address token) internal {
        IERC20(token).forceApprove(uniswapV2Router, 0);
    }

    /**
     * @dev 退还 token。
     *
     * 大白话：
     * 加流动性时没用完的 token，会通过这里退给用户。
     */
    function _refund(address token, address to, uint256 amount) internal {
        if (amount > 0) {
            IERC20(token).safeTransfer(to, amount);
            emit Refund(token, to, amount);
        }
    }
}