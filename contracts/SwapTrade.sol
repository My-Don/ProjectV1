// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// OpenZeppelin 5.x 写法：Ownable 需要传 initialOwner
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @dev Uniswap V2 Factory 的最小接口。
 * 大白话：只要能查“两个 token 有没有交易对”就够了。
 */
interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/**
 * @dev Uniswap V2 Router 的最小接口。
 * 大白话：这里只声明本合约真正会用到的几个函数。
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
 * @dev 基于 Uniswap V2 Router 的 BKC / SNC / USDT 兑换与流动性管理合约。
 *
 * 大白话说明：
 * 1. 用户可以用本合约换币。
 * 2. 合约会自动比较“直接交易”和“走 USDT 中转”哪条路径拿到更多。
 * 3. 用户可以添加、移除流动性。
 * 4. 加流动性时没用完的钱，会自动退回给用户。
 * 5. owner 可以暂停合约，防止遇到异常时继续被用。
 *
 * 重要限制：
 * - 本版本只允许 BKC / SNC / USDT 三种 token。
 * - 本版本不支持 fee-on-transfer、扣税币、反射币等非标准 ERC20。
 * - 本版本不处理原生 ETH 交易，只处理 ERC20。ETH 只允许误转后由 owner 提出。
 */
contract SwapTrade is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ========== 核心地址 ==========

    // 大白话：Uniswap V2 Router 地址，所有换币、加池、移除池都通过它执行。
    address public immutable uniswapV2Router;

    // 大白话：Uniswap V2 Factory 地址，用来查交易对 pair。
    address public immutable factory;

    // 大白话：项目里的三个指定 token。
    address public immutable bkc;
    address public immutable snc;
    address public immutable usdt;

    // ========== 常量 ==========

    // 大白话：最大自动滑点 5%。100 = 1%，500 = 5%。
    uint256 public constant MAX_SLIPPAGE_BPS = 500;

    // 大白话：基点分母。10000 = 100%。
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // 大白话：如果用户不传 deadline，就默认 30 分钟后过期。
    uint256 public constant DEFAULT_DEADLINE_SECONDS = 1800;

    // 大白话：owner 批量提 token 时最多一次 100 个，防止数组太大把 gas 打爆。
    uint256 private constant MAX_ARRAY_SIZE = 100;

    /**
     * @dev 添加流动性的参数。
     * 大白话：为了避免函数参数太多，把加池需要的信息打包成一个结构体。
     */
    struct LiquidityParams {
        address tokenA;       // tokenA 地址
        address tokenB;       // tokenB 地址
        uint256 amountA;      // 用户愿意拿出来的 tokenA 数量
        uint256 amountB;      // 用户愿意拿出来的 tokenB 数量
        uint256 amountAMin;   // 最少要实际加进去多少 tokenA
        uint256 amountBMin;   // 最少要实际加进去多少 tokenB
        address to;           // LP token 给谁
        uint256 deadline;     // 过期时间，传 0 就默认 30 分钟
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

    /**
     * @dev 构造函数。
     *
     * 大白话：
     * 部署时把 BKC、SNC、USDT、Router 地址传进来。
     * Factory 地址从 Router 里自动读取。
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

        // 大白话：三个 token 不能传成同一个地址，不然路径判断会乱。
        require(_bkc != _snc && _bkc != _usdt && _snc != _usdt, "duplicate token");

        // 大白话：Router 必须真的是合约，不能是普通钱包地址。
        require(_uniswapV2Router.code.length > 0, "router no code");

        address _factory = IUniswapV2Router02(_uniswapV2Router).factory();
        require(_factory != address(0), "factory zero");
        require(_factory.code.length > 0, "factory no code");

        bkc = _bkc;
        snc = _snc;
        usdt = _usdt;
        uniswapV2Router = _uniswapV2Router;
        factory = _factory;
    }

    // ========== owner 管理函数 ==========

    /**
     * @dev 暂停交易、加池、移除池。
     * 大白话：出事时 owner 可以一键暂停，避免继续扩大损失。
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev 恢复交易、加池、移除池。
     * 大白话：问题修好后 owner 再打开。
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ========== 查询函数 ==========

    /**
     * @dev 判断某个 token 是否是本合约支持的 token。
     * 大白话：这里只允许 BKC、SNC、USDT。
     */
    function isSupportedToken(address token) public view returns (bool) {
        return token == bkc || token == snc || token == usdt;
    }

    /**
     * @dev 查两个 token 的交易对地址。
     * 大白话：如果没有 pair，返回 address(0)。
     */
    function getPair(address tokenA, address tokenB) external view returns (address) {
        require(tokenA != address(0) && tokenB != address(0), "zero address");
        if (tokenA == tokenB) return address(0);
        return _getPair(tokenA, tokenB);
    }

    /**
     * @dev 前端用：预测能换多少，以及实际会走哪条路径。
     *
     * 大白话：
     * 例如 BKC -> SNC：
     * - 如果 BKC/SNC 直接池子更划算，就直接换。
     * - 如果 BKC/USDT/SNC 更划算，就走 USDT 中转。
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
     * @dev 查询某账户某 token 的余额。
     * 大白话：给前端用，方便展示余额。
     */
    function getAccountBalance(address token, address account) external view returns (uint256) {
        require(token != address(0) && account != address(0), "zero address");
        return IERC20(token).balanceOf(account);
    }

    // ========== 换币函数 ==========

    /**
     * @dev 自动滑点版本的换币函数。
     *
     * 大白话：
     * 用户传入滑点，比如 100 表示 1%。
     * 合约会先根据当前池子报价，然后自动算 amountOutMin。
     *
     * 提醒：
     * 真实生产前端更推荐使用 swapWithMinOut，
     * 因为用户自己传 amountOutMin，价格保护更明确。
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
        require(to != address(0), "to zero");
        require(amountIn > 0, "amountIn = 0");
        require(slippageBps <= MAX_SLIPPAGE_BPS, "slippage too large");

        (uint256 quotedOut, address[] memory path) = _bestQuoteAndPath(tokenIn, tokenOut, amountIn);
        uint256 amountOutMin = _amountOutMin(quotedOut, slippageBps);
        uint256 finalDeadline = _finalDeadline(deadline);

        amountOut = _swapUsingPath(
            msg.sender,
            tokenIn,
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
     * @dev 手动指定最小输出数量的换币函数。
     *
     * 大白话：
     * 这是更推荐的生产用法。
     * 前端先报价，用户确认“我至少要拿到多少 tokenOut”，
     * 然后把 amountOutMin 传进来。
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
        require(to != address(0), "to zero");
        require(amountIn > 0, "amountIn = 0");
        require(amountOutMin > 0, "minOut = 0");

        (uint256 quotedOut, address[] memory path) = _bestQuoteAndPath(tokenIn, tokenOut, amountIn);

        // 大白话：如果当前报价连用户要求的最低数量都达不到，就直接失败，省得白白花 gas。
        require(quotedOut >= amountOutMin, "minOut too high");

        uint256 finalDeadline = _finalDeadline(deadline);

        amountOut = _swapUsingPath(
            msg.sender,
            tokenIn,
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

    // ========== 流动性函数 ==========

    /**
     * @dev 添加流动性。
     *
     * 大白话：
     * 用户把 tokenA/tokenB 授权给本合约。
     * 本合约先把币转进来，再授权给 Router。
     * Router 实际用多少就用多少，剩下的自动退给用户。
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
        require(p.to != address(0), "to zero");
        require(p.amountA > 0 && p.amountB > 0, "amount zero");
        require(p.amountAMin <= p.amountA, "bad amountAMin");
        require(p.amountBMin <= p.amountB, "bad amountBMin");

        address sender = msg.sender;
        uint256 finalDeadline = _finalDeadline(p.deadline);

        // 大白话：先把用户愿意拿出来的两个 token 转到本合约。
        // 这里要求必须完整到账，不支持扣税币、转账手续费币。
        _pullExactToken(p.tokenA, sender, p.amountA);
        _pullExactToken(p.tokenB, sender, p.amountB);

        // 大白话：只给 Router 授权本次需要的额度，不给无限授权。
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

        require(liquidity > 0, "no liquidity");

        // 大白话：Router 用完后，把剩余授权清掉，减少风险。
        _clearRouterApproval(p.tokenA);
        _clearRouterApproval(p.tokenB);

        // 大白话：加池通常不会刚好用完两边金额，没用完的要退给用户。
        if (p.amountA > amountAActual) {
            _refund(p.tokenA, sender, p.amountA - amountAActual);
        }

        if (p.amountB > amountBActual) {
            _refund(p.tokenB, sender, p.amountB - amountBActual);
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
     * 本合约把 LP token 转进来，再通过 Router 拆回 tokenA/tokenB。
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
        require(to != address(0), "to zero");
        require(liquidity > 0, "liquidity = 0");

        _requireSupportedPair(tokenA, tokenB);

        // 大白话：确认用户传进来的 LP 地址真的是 tokenA/tokenB 的 pair。
        address pair = _getPair(tokenA, tokenB);
        require(pair != address(0), "pair not exist");
        require(pair == lpToken, "LP mismatch");

        uint256 finalDeadline = _finalDeadline(deadline);

        // 大白话：把用户的 LP token 转到本合约。
        _pullExactToken(lpToken, msg.sender, liquidity);

        // 大白话：只授权本次要拆掉的 LP 数量。
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

        // 大白话：拆完池后清掉 LP 授权。
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
     * @dev owner 提取合约里的 ERC20。
     *
     * 大白话：
     * 正常情况下，用户加池剩余 token 会自动退回。
     * 这个函数主要用于处理别人误转进来的 token。
     */
    function withdraw(address[] calldata tokens, address to) external onlyOwner nonReentrant {
        require(to != address(0), "to zero");

        uint256 len = tokens.length;
        require(len > 0 && len <= MAX_ARRAY_SIZE, "bad array length");

        for (uint256 i = 0; i < len; ) {
            address token = tokens[i];
            require(token != address(0), "token zero");

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
     * @dev owner 提取 ETH。
     *
     * 大白话：
     * 本合约不做 ETH 交易，但别人可能误转 ETH 进来。
     * 用 call，不用 transfer，兼容性更好。
     */
    function withdrawETH(address payable to) external onlyOwner nonReentrant {
        require(to != address(0), "to zero");

        uint256 amount = address(this).balance;
        require(amount > 0, "no ETH");

        (bool ok, ) = to.call{value: amount}("");
        require(ok, "ETH transfer failed");

        emit Withdraw(address(0), to, amount);
    }

    /**
     * @dev 接收 ETH。
     *
     * 大白话：
     * 只为了兼容误转 ETH 或特殊场景。
     * 本合约没有 ETH 换币逻辑。
     */
    receive() external payable {}

    // ========== 内部工具函数 ==========

    /**
     * @dev 检查一对 token 是否允许使用。
     *
     * 大白话：
     * 不能是 0 地址，不能两个 token 一样，必须是 BKC/SNC/USDT 里的两个。
     */
    function _requireSupportedPair(address tokenA, address tokenB) internal view {
        require(tokenA != address(0) && tokenB != address(0), "zero address");
        require(tokenA != tokenB, "same token");
        require(isSupportedToken(tokenA) && isSupportedToken(tokenB), "unsupported token");
    }

    /**
     * @dev 从 Factory 查询 pair。
     *
     * 大白话：
     * 只负责查 pair，不负责判断这个 pair 有没有流动性。
     */
    function _getPair(address tokenA, address tokenB) internal view returns (address pair) {
        if (tokenA == tokenB) return address(0);
        pair = IUniswapV2Factory(factory).getPair(tokenA, tokenB);
    }

    /**
     * @dev 选出最优路径，并返回这条路径的报价。
     *
     * 大白话：
     * 会比较：
     * 1. tokenIn -> tokenOut
     * 2. tokenIn -> USDT -> tokenOut
     *
     * 谁输出更多，就用谁。
     */
    function _bestQuoteAndPath(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (uint256 bestOut, address[] memory bestPath) {
        uint256 directOut;
        address[] memory directPath;

        // 大白话：先看有没有直接交易对。
        if (_getPair(tokenIn, tokenOut) != address(0)) {
            directPath = new address[](2);
            directPath[0] = tokenIn;
            directPath[1] = tokenOut;

            directOut = _quoteSafe(amountIn, directPath);
        }

        uint256 usdtOut;
        address[] memory usdtPath;

        // 大白话：如果本来就有 USDT，就没必要再走 USDT 中转。
        if (tokenIn != usdt && tokenOut != usdt) {
            bool hasInUsdtPair = _getPair(tokenIn, usdt) != address(0);
            bool hasOutUsdtPair = _getPair(usdt, tokenOut) != address(0);

            if (hasInUsdtPair && hasOutUsdtPair) {
                usdtPath = new address[](3);
                usdtPath[0] = tokenIn;
                usdtPath[1] = usdt;
                usdtPath[2] = tokenOut;

                usdtOut = _quoteSafe(amountIn, usdtPath);
            }
        }

        require(directOut > 0 || usdtOut > 0, "no liquidity");

        // 大白话：USDT 中转更多，就走 USDT；否则默认走直接路径。
        if (usdtOut > directOut) {
            return (usdtOut, usdtPath);
        }

        return (directOut, directPath);
    }

    /**
     * @dev 安全报价。
     *
     * 大白话：
     * 如果某条路径不存在、没流动性、Router 报错，就返回 0，
     * 这样不会影响另一条路径比较。
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
     * @dev 按滑点计算最低接收数量。
     *
     * 大白话：
     * quotedOut = 预计能拿到多少。
     * slippageBps = 用户愿意接受多少滑点。
     * 例如 quotedOut = 100，滑点 1%，最低接收就是 99。
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
     * 用户传 0，就默认 30 分钟；
     * 用户传了具体时间，就不能是过去时间。
     */
    function _finalDeadline(uint256 deadline) internal view returns (uint256) {
        if (deadline == 0) {
            return block.timestamp + DEFAULT_DEADLINE_SECONDS;
        }

        require(deadline >= block.timestamp, "deadline expired");
        return deadline;
    }

    /**
     * @dev 按指定路径执行换币。
     *
     * 大白话：
     * 1. 把用户 tokenIn 转到本合约。
     * 2. 本合约授权 Router。
     * 3. Router 去换币。
     * 4. 清掉授权。
     */
    function _swapUsingPath(
        address payer,
        address tokenIn,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline,
        address[] memory path
    ) internal returns (uint256 amountOut) {
        require(path.length >= 2, "bad path");
        require(path[0] == tokenIn, "path token mismatch");

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
        require(amountOut >= amountOutMin, "insufficient output");
    }

    /**
     * @dev 从用户那里拉 token，并要求完整到账。
     *
     * 大白话：
     * 如果用户转 100，合约必须收到 100。
     * 如果只收到 99，说明这个 token 可能有手续费/扣税，本合约不支持。
     */
    function _pullExactToken(address token, address from, uint256 amount) internal {
        require(amount > 0, "amount zero");

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(from, address(this), amount);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));

        require(balanceAfter - balanceBefore == amount, "fee token unsupported");
    }

    /**
     * @dev 给 Router 授权本次要用的数量。
     *
     * 大白话：
     * 不给无限授权，用多少批多少。
     * forceApprove 可以兼容 USDT 这类“改授权前要先清零”的 token。
     */
    function _approveRouter(address token, uint256 amount) internal {
        IERC20(token).forceApprove(uniswapV2Router, amount);
    }

    /**
     * @dev 清掉 Router 授权。
     *
     * 大白话：
     * 用完就把授权清零，减少 Router 地址出问题时的风险。
     */
    function _clearRouterApproval(address token) internal {
        uint256 allowance = IERC20(token).allowance(address(this), uniswapV2Router);

        if (allowance > 0) {
            IERC20(token).forceApprove(uniswapV2Router, 0);
        }
    }

    /**
     * @dev 退还没用完的 token。
     *
     * 大白话：
     * 加池时没花完的钱，不能留在合约里，直接退给用户。
     */
    function _refund(address token, address to, uint256 amount) internal {
        if (amount > 0) {
            IERC20(token).safeTransfer(to, amount);
            emit Refund(token, to, amount);
        }
    }
}