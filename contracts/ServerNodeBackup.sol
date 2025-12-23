// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@uniswap/lib/contracts/libraries/TransferHelper.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

// 计数器库（用于生成唯一ID）
library Counters {
    struct Counter {
        uint256 _value;
    }

    function current(Counter storage counter) internal view returns (uint256) {
        return counter._value;
    }

    function increment(Counter storage counter) internal {
        unchecked {
            counter._value += 1;
        }
    }

    function decrement(Counter storage counter) internal {
        uint256 value = counter._value;
        require(value > 0, "Counter: decrement overflow");
        unchecked {
            counter._value = value - 1;
        }
    }

    function reset(Counter storage counter) internal {
        counter._value = 0;
    }
}

/**
 * @title ServerNodeBackup
 * @notice 服务器节点合约
 * 功能：管理节点、分配奖励、多签提款、白名单控制
 */
contract ServerNodeBackup is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    // ==================== 常量配置 ====================
    uint256 public constant BIGNODE = 2000;      // 最大物理节点数
    uint256 public constant BASENODE = 500;      // 基础节点数（用于奖励计算）

    // ==================== 核心状态变量 ====================
    using Counters for Counters.Counter;
    Counters.Counter private _counter; // 节点ID计数器

    address private BKC;                          // BKC代币合约地址
    address private REWARD;                       // 奖励计算器合约地址

    uint256 public totalPhysicalNodes;            // 总物理节点数
    uint256 public totalNodesSold;                // 总售出节点数
    NodeInfo[] public deployNode;                 // 已部署节点信息

    mapping(address => uint256) public lastUserRewardTime;  // 用户最后奖励时间
    mapping(address => mapping(uint16 => bool)) private hasRewarded;  // 用户奖励记录

    // ==================== 资金提取多签系统 ====================
    address[] private withdrawSigners;            // 提款签名者列表
    uint256 private withdrawThreshold;            // 提款多签阈值（需要多少人确认）
    mapping(address => bool) private isWithdrawSigner;  // 签名者映射
    uint256 private withdrawMultiSigNonce;        // 提款Nonce（未使用）

    // 提款提案结构
    struct WithdrawalProposal {
        address proposer;          // 提议者
        address token;             // 代币地址
        address payable recipient; // 接收地址
        uint256 amount;            // 提款数量
        uint256 confirmations;     // 已确认人数
        bool executed;             // 是否已执行
        uint256 createdAt;         // 创建时间
    }

    WithdrawalProposal[] private withdrawalProposals;  // 提款提案列表
    mapping(uint256 => mapping(address => bool)) private withdrawalConfirmations;  // 确认记录

    // ==================== 节点信息结构 ====================
    struct NodeInfo {
        string ip;                 // 节点IP
        string describe;           // 节点描述
        string name;               // 节点名称
        bool isActive;             // 是否激活
        uint8 typeParam;           // 节点类型（1-4）
        uint256 id;                // 节点ID
        uint256 capacity;          // 节点容量
        uint256 createTime;        // 创建时间
        uint256 blockHeight;       // 区块高度
    }

    struct configNodeParams {
        address stakeAddress;      // 质押地址（节点所有者）
        bool isActive;             // 是否激活
        uint8 typeParam;           // 节点类型
        uint256 id;                // 节点ID
        uint256 nodeCapacity;      // 节点容量
        uint256 nodeMoney;         // 节点价值（用于类型4）
        uint256 createTime;        // 创建时间
        uint256 blockHeight;       // 区块高度
    }

    // ====================白名单和节点映射 ====================
    mapping(address => bool) public whiteList;                    // 白名单用户
    mapping(address => configNodeParams[]) public buyNode;        // 用户购买的节点
    mapping(uint256 => configNodeParams[]) public getBuyNodeById; // 通过ID查询节点
    mapping(address => uint256) public userPhysicalNodes;         // 用户物理节点数

    // ==================== 修饰符 ====================
    modifier onlyEOA() {
        require(msg.sender == tx.origin, "Only EOA");
        _;
    }

    modifier onlyWithdrawMultiSig() {
        require(isWithdrawSigner[msg.sender], "Not authorized: caller is not a withdrawal signer");
        _;
    }

    modifier withdrawalProposalExists(uint256 proposalId) {
        require(proposalId < withdrawalProposals.length, "Withdrawal proposal does not exist");
        require(!withdrawalProposals[proposalId].executed, "Withdrawal proposal already executed");
        _;
    }

    modifier notWithdrawConfirmed(uint256 proposalId) {
        require(!withdrawalConfirmations[proposalId][msg.sender], "Already confirmed this withdrawal");
        _;
    }

    // ==================== 事件 ====================
    event CreateNodeInfo(string indexed ip, string describe, string indexed name, bool isActive, uint8 typeParam, uint256 id, uint256 indexed capacity, uint256 blockTime, uint256 blockHeight);
    event ConfigNodeInfo(address indexed stakeAddress, bool isActive, uint8 typeParam, uint256 id, uint256 indexed capacity, uint256 money, uint256 blockTime, uint256 blockHeight);
    event RewardDistributed(address indexed user, uint256 indexed amount, uint16 year);
    event RewardPaused(address indexed admin);
    event RewardUnpaused(address indexed admin);
    event RewardAttempt(address indexed user, uint16 year, uint256 timestamp);
    event BatchRewardsDistributed(uint256 indexed totalUsers, uint256 indexed totalAmount, uint16 year);
    event WithdrawSignerAdded(address indexed signer);
    event WithdrawSignerRemoved(address indexed signer);
    event WithdrawThresholdUpdated(uint256 newThreshold);
    event WithdrawMultiSigInitialized(address[] signers, uint256 threshold);
    event WithdrawalProposalSubmitted(uint256 indexed proposalId, address indexed proposer, address indexed token, address recipient, uint256 amount);
    event WithdrawalProposalConfirmed(uint256 indexed proposalId, address indexed signer);
    event WithdrawalProposalExecuted(uint256 indexed proposalId, address indexed executor, address indexed token, address recipient, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice 合约初始化
     * @param _owner 合约所有者
     * @param _rewardCalculator 奖励计算器地址
     * @param _bkc BKC代币地址
     * @param _signers 多签签名者数组
     * @param _threshold 多签阈值（需要多少人确认）
     */
    function initialize(
        address _owner,
        address _rewardCalculator,
        address _bkc,
        address[] calldata _signers,
        uint256 _threshold
    ) public initializer {
        __Ownable_init(msg.sender);
        transferOwnership(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();

        require(_rewardCalculator != address(0), "Reward calculator address is zero");
        require(_bkc != address(0), "Invalid BKC");
        BKC = _bkc;
        REWARD = _rewardCalculator;

        require(withdrawSigners.length == 0, "Withdrawal MultiSig already initialized");
        require(_threshold > 0, "Threshold must be > 0");
        require(_threshold <= _signers.length, "Threshold exceeds signers count");

        // 多签数组
        for (uint i = 0; i < _signers.length; i++) {
            require(_signers[i] != address(0), "Invalid signer address");
            require(!isWithdrawSigner[_signers[i]], "Signer already exists");
            withdrawSigners.push(_signers[i]);
            isWithdrawSigner[_signers[i]] = true;
            emit WithdrawSignerAdded(_signers[i]);
        }

        withdrawThreshold = _threshold;
        emit WithdrawThresholdUpdated(_threshold);
        emit WithdrawMultiSigInitialized(_signers, _threshold);
    }

    // ==================== 资金提取多签管理 ====================

    /**
     * @notice 添加提款签名者（需要多签批准）
     * @param _signer 新签名者地址
     */
    function addWithdrawSigner(address _signer) external onlyWithdrawMultiSig {
        require(_signer != address(0), "Invalid address");
        require(!isWithdrawSigner[_signer], "Already a signer");

        withdrawSigners.push(_signer);
        isWithdrawSigner[_signer] = true;
        emit WithdrawSignerAdded(_signer);
    }

    /**
     * @notice 移除提款签名者（需要多签批准）
     * @param _signer 要移除的签名者地址
     */
    function removeWithdrawSigner(address _signer) external onlyWithdrawMultiSig {
        require(isWithdrawSigner[_signer], "Not a signer");
        require(withdrawSigners.length > withdrawThreshold, "Cannot remove below threshold");

        for (uint i = 0; i < withdrawSigners.length; i++) {
            if (withdrawSigners[i] == _signer) {
                withdrawSigners[i] = withdrawSigners[withdrawSigners.length - 1];
                withdrawSigners.pop();
                break;
            }
        }

        delete isWithdrawSigner[_signer];
        emit WithdrawSignerRemoved(_signer);
    }

    /**
     * @notice 更新提款阈值（需要多签批准）
     * @param _threshold 新阈值
     */
    function updateWithdrawThreshold(uint256 _threshold) external onlyWithdrawMultiSig {
        require(_threshold > 0, "Threshold must be > 0");
        require(_threshold <= withdrawSigners.length, "Threshold exceeds signers count");

        withdrawThreshold = _threshold;
        emit WithdrawThresholdUpdated(_threshold);
    }

    // ==================== 资金提取操作 ====================

    /**
     * @notice 提交提款提案
     * @param _token 代币地址（BKC或其他）
     * @param _recipient 接收地址
     * @param _amount 提款数量
     * @return proposalId 提案ID
     */
    function proposeWithdrawal(address _token, address payable _recipient, uint256 _amount) external onlyWithdrawMultiSig returns (uint256 proposalId) {
        require(_token != address(0), "Invalid token address");
        require(_recipient != address(0), "Invalid recipient address");
        require(_amount > 0, "Amount must be > 0");

        // 查看合约是否有足够余额
        uint256 balance = IERC20(_token).balanceOf(address(this));
        require(balance >= _amount, "Insufficient contract balance");

        proposalId = withdrawalProposals.length;
        withdrawalProposals.push(WithdrawalProposal({
            proposer: msg.sender,
            token: _token,
            recipient: _recipient,
            amount: _amount,
            confirmations: 0,
            executed: false,
            createdAt: block.timestamp
        }));

        emit WithdrawalProposalSubmitted(proposalId, msg.sender, _token, _recipient, _amount);
        return proposalId;
    }

    /**
     * @notice 确认提款提案
     * @param proposalId 提案ID
     */
    function confirmWithdrawal(uint256 proposalId) external onlyWithdrawMultiSig withdrawalProposalExists(proposalId) notWithdrawConfirmed(proposalId) {
        WithdrawalProposal storage proposal = withdrawalProposals[proposalId];
        proposal.confirmations += 1;
        withdrawalConfirmations[proposalId][msg.sender] = true;
        emit WithdrawalProposalConfirmed(proposalId, msg.sender);
    }

    /**
     * @notice 执行提款提案（达到阈值后可执行）
     * @param proposalId 提案ID
     */
    function executeWithdrawal(uint256 proposalId) external withdrawalProposalExists(proposalId) nonReentrant {
        WithdrawalProposal storage proposal = withdrawalProposals[proposalId];
        require(proposal.confirmations >= withdrawThreshold, "Not enough confirmations");
        require(!proposal.executed, "Already executed");

        proposal.executed = true;

        uint256 balance = IERC20(proposal.token).balanceOf(address(this));
        require(balance >= proposal.amount, "Insufficient balance");

        bool success = IERC20(proposal.token).transfer(proposal.recipient, proposal.amount);
        require(success, "Token transfer failed");

        emit WithdrawalProposalExecuted(proposalId, msg.sender, proposal.token, proposal.recipient, proposal.amount);
    }

    /**
     * @notice 快速执行提款（确认+执行一步完成）
     * @param proposalId 提案ID
     */
    function confirmAndExecuteWithdrawal(uint256 proposalId) external onlyWithdrawMultiSig withdrawalProposalExists(proposalId) notWithdrawConfirmed(proposalId) nonReentrant {
        WithdrawalProposal storage proposal = withdrawalProposals[proposalId];

        // 先确认
        proposal.confirmations += 1;
        withdrawalConfirmations[proposalId][msg.sender] = true;
        emit WithdrawalProposalConfirmed(proposalId, msg.sender);

        // 检查是否达到阈值
        if (proposal.confirmations >= withdrawThreshold && !proposal.executed) {
            proposal.executed = true;

            bool success = IERC20(proposal.token).transfer(proposal.recipient, proposal.amount);
            require(success, "Token transfer failed");

            emit WithdrawalProposalExecuted(proposalId, msg.sender, proposal.token, proposal.recipient, proposal.amount);
        }
    }

    /**
     * @notice 查询提款提案信息
     * @param proposalId 提案ID
     */
    function getWithdrawalProposal(uint256 proposalId) external view returns (address proposer, address token, address payable recipient, uint256 amount, uint256 confirmations, bool executed, uint256 createdAt) {
        require(proposalId < withdrawalProposals.length, "Withdrawal proposal does not exist");
        WithdrawalProposal storage p = withdrawalProposals[proposalId];
        return (p.proposer, p.token, p.recipient, p.amount, p.confirmations, p.executed, p.createdAt);
    }

    /**
     * @notice 查询提案确认状态
     * @param proposalId 提案ID
     * @param signer 签名者地址
     */
    function hasWithdrawalConfirmed(uint256 proposalId, address signer) external view returns (bool) {
        return withdrawalConfirmations[proposalId][signer];
    }

    // ==================== 节点管理 ====================

    /**
     * @notice 管理员创建节点
     * @param _nodeInfo 节点信息数组
     */
    function createNode(NodeInfo[] calldata _nodeInfo) public onlyOwner {
        uint256 length = _nodeInfo.length;
        require(length > 0, "Node information cannot be an empty array.");

        for (uint256 i = 0; i < length; i++) {
            _counter.increment();
            uint256 newId = _counter.current();

            deployNode.push(NodeInfo({
                ip: _nodeInfo[i].ip,
                describe: _nodeInfo[i].describe,
                name: _nodeInfo[i].name,
                isActive: _nodeInfo[i].isActive,
                typeParam: _nodeInfo[i].typeParam,
                id: newId,
                capacity: _nodeInfo[i].capacity,
                createTime: _nodeInfo[i].createTime == 0 ? block.timestamp : _nodeInfo[i].createTime,
                blockHeight: _nodeInfo[i].blockHeight == 0 ? block.number : _nodeInfo[i].blockHeight
            }));

            emit CreateNodeInfo(_nodeInfo[i].ip, _nodeInfo[i].describe, _nodeInfo[i].name, _nodeInfo[i].isActive, _nodeInfo[i].typeParam, _counter.current(), _nodeInfo[i].capacity, block.timestamp, block.number);
        }
    }

    /**
     * @notice 配置节点信息（管理员或白名单用户才能调用）
     * @param _buyNodeInfo 节点配置数组
     */
    function configNode(configNodeParams[] calldata _buyNodeInfo) public nonReentrant {
        address from = _msgSender();
        require(owner() == from || whiteList[from], "Only whitelist or Only Owner");

        uint256 length = _buyNodeInfo.length;
        require(length > 0 && length <= 20, "Node information array must be between 1 and 20 items.");

        uint256 physicalNodesToAdd = 0;

        // 第一步：计算和验证节点
        for (uint256 i = 0; i < length; i++) {
            uint8 nodeType = _buyNodeInfo[i].typeParam;
            uint256 nodeValue = _buyNodeInfo[i].nodeMoney;
            uint256 physicalNodeCount = 0;

            require(nodeType >= 1 && nodeType <= 4, "Invalid node type");

            // 根据节点类型计算物理节点数量
            if (nodeType == 1) {
                physicalNodeCount = 1;  // 大节点 = 1物理节点
            } else if (nodeType == 2) {
                physicalNodeCount = _buyNodeInfo[i].nodeCapacity / 5;  // 中节点 = 5个=1物理节点
            } else if (nodeType == 3) {
                physicalNodeCount = _buyNodeInfo[i].nodeCapacity / 20; // 小节点 = 20个=1物理节点
            } else if (nodeType == 4) {
                physicalNodeCount = nodeValue / 1e6;  // 商品节点 = 价值/100万
                require(physicalNodeCount > 0, "Node value too low");
            }

            require(getBuyNodeById[_buyNodeInfo[i].id].length == 0, "Node ID already exists");
            physicalNodesToAdd += physicalNodeCount;

            // 存储节点信息
            address stakeAddress = _buyNodeInfo[i].stakeAddress;
            buyNode[stakeAddress].push(configNodeParams({
                stakeAddress: _buyNodeInfo[i].stakeAddress,
                isActive: _buyNodeInfo[i].isActive,
                typeParam: nodeType,
                id: _buyNodeInfo[i].id,
                nodeCapacity: _buyNodeInfo[i].nodeCapacity,
                nodeMoney: nodeValue,
                createTime: _buyNodeInfo[i].createTime == 0 ? block.timestamp : _buyNodeInfo[i].createTime,
                blockHeight: _buyNodeInfo[i].blockHeight == 0 ? block.number : _buyNodeInfo[i].blockHeight
            }));

            getBuyNodeById[_buyNodeInfo[i].id].push(configNodeParams({
                stakeAddress: _buyNodeInfo[i].stakeAddress,
                isActive: _buyNodeInfo[i].isActive,
                typeParam: nodeType,
                id: _buyNodeInfo[i].id,
                nodeCapacity: _buyNodeInfo[i].nodeCapacity,
                nodeMoney: nodeValue,
                createTime: _buyNodeInfo[i].createTime == 0 ? block.timestamp : _buyNodeInfo[i].createTime,
                blockHeight: _buyNodeInfo[i].blockHeight == 0 ? block.number : _buyNodeInfo[i].blockHeight
            }));

            emit ConfigNodeInfo(_buyNodeInfo[i].stakeAddress, _buyNodeInfo[i].isActive, nodeType, _buyNodeInfo[i].id, _buyNodeInfo[i].nodeCapacity, nodeValue, block.timestamp, block.number);
        }

        require(totalPhysicalNodes + physicalNodesToAdd <= BIGNODE, "Exceeds maximum physical nodes limit");

        // 更新总节点数
        totalPhysicalNodes += physicalNodesToAdd;
        totalNodesSold += physicalNodesToAdd;

        // 第二步：为每个用户单独更新节点数
        for (uint256 i = 0; i < length; i++) {
            address stakeAddress = _buyNodeInfo[i].stakeAddress;
            uint8 nodeType = _buyNodeInfo[i].typeParam;
            uint256 nodeValue = _buyNodeInfo[i].nodeMoney;
            uint256 physicalNodeCount = 0;

            if (nodeType == 1) {
                physicalNodeCount = 1;
            } else if (nodeType == 2) {
                physicalNodeCount = _buyNodeInfo[i].nodeCapacity / 5;
            } else if (nodeType == 3) {
                physicalNodeCount = _buyNodeInfo[i].nodeCapacity / 20;
            } else if (nodeType == 4) {
                physicalNodeCount = nodeValue / 1e6;
            }

            userPhysicalNodes[stakeAddress] += physicalNodeCount;
        }
    }

    /**
     * @notice 配置白名单
     * @param user 用户地址
     * @param _isTrue 是否加入白名单
     */
    function setWhiteList(address user, bool _isTrue) external onlyOwner {
        whiteList[user] = _isTrue;
    }

    /**
     * @notice 管理员充值BKC
     * @param amount 充值数量
     */
    function depositToken(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "amount must be than 0");
        require(IERC20(BKC).allowance(owner(), address(this)) >= amount, "BKC allowance not sufficient");
        TransferHelper.safeTransferFrom(BKC, msg.sender, address(this), amount);
    }

    /**
     * @notice 查询合约内的BKC余额
     */
    function getTokenBalance() external view returns (uint256) {
        return IERC20(BKC).balanceOf(address(this));
    }

    /**
     * @notice 检查状态一致性（总节点数是否匹配）
     */
    function checkStateConsistency() external view returns (bool) {
        return totalPhysicalNodes == totalNodesSold;
    }

    /**
     * @notice 根据节点ID范围查询用户节点配置
     * @param user 用户地址
     * @param startId 起始ID
     * @param endId 结束ID
     */
    function getConfigNodeInfo(address user, uint256 startId, uint256 endId) external view returns (configNodeParams[] memory) {
        require(user != address(0), "Invalid user address");
        require(startId >= 1 && endId >= startId, "Invalid ID range");

        configNodeParams[] storage userNodes = buyNode[user];
        uint256 nodeCount = userNodes.length;

        if (nodeCount == 0) {
            return new configNodeParams[](0);
        }

        uint256 matchCount = 0;
        for (uint256 i = 0; i < nodeCount; i++) {
            uint256 nodeId = userNodes[i].id;
            if (nodeId >= startId && nodeId <= endId) {
                matchCount++;
            }
        }

        configNodeParams[] memory result = new configNodeParams[](matchCount);
        uint256 resultIndex = 0;

        for (uint256 i = 0; i < nodeCount; i++) {
            uint256 nodeId = userNodes[i].id;
            if (nodeId >= startId && nodeId <= endId) {
                result[resultIndex] = userNodes[i];
                resultIndex++;
            }
        }

        return result;
    }

    /**
     * @notice 查询每日奖励统计（内部调用奖励计算器）
     * @param _year 年份
     */
    function getDailyRewards(uint16 _year) internal view returns (uint256) {
        (bool success, bytes memory data) = REWARD.staticcall(abi.encodeWithSignature("getYearlyRewardInfo(uint256)", _year));
        require(success && data.length >= 64, "Query quantity failed");
        (uint256 amount, ) = abi.decode(data, (uint256, bool));
        return amount;
    }

    /**
     * @notice 批量分配奖励（每24小时调用一次）
     * @param _users 配置了节点的用户地址数组
     * @param _year 年份（1-30）
     * @dev 外部定时调用，给用户分配每日奖励
     */
    function configRewards(address[] calldata _users, uint16 _year) external onlyOwner nonReentrant whenNotPaused {
        require(_users.length > 0, "Users array cannot be empty");
        require(_users.length <= 50, "Too many users, maximum 50 per batch");
        require(_year >= 1 && _year <= 30, "Invalid year");

        // 1. 获取该年份的每日奖励基数
        uint256 yearlyReward = getDailyRewards(_year);
        require(yearlyReward > 0, "Reward is zero");

        // 2. 计算有效总节点数（至少500）
        uint256 effectiveTotalNodes = totalNodesSold < BASENODE ? BASENODE : totalNodesSold;
        require(effectiveTotalNodes > 0, "No physical nodes sold yet");

        uint256 totalDistributed = 0;
        uint256 usersProcessed = 0;

        // 3. 遍历用户，分配奖励
        for (uint256 i = 0; i < _users.length; i++) {
            address user = _users[i];
            require(user != address(0), "Invalid user address");

            // 检查冷却期（24小时内是否已奖励）
            if (hasRewarded[user][_year]) {
                if (block.timestamp < lastUserRewardTime[user] + 24 hours) {
                    continue;  // 跳过，未到24小时
                } else {
                    hasRewarded[user][_year] = false;  // 重置标记
                }
            }

            // 检查用户是否有节点
            uint256 userPhysicalNodeCount = userPhysicalNodes[user];
            if (userPhysicalNodeCount == 0) {
                continue;  //无节点，跳过
            }

            // 计算奖励：(每日奖励 × 用户节点数) / 总节点数
            uint256 rewardAmount = (yearlyReward * userPhysicalNodeCount) / effectiveTotalNodes;

            if (rewardAmount == 0) {
                continue;  // 奖励为0，跳过
            }

            // 检查合约余额是否充足
            uint256 contractBalance = IERC20(BKC).balanceOf(address(this));
            require(contractBalance >= rewardAmount, "Insufficient contract balance");

            // 执行转账
            TransferHelper.safeTransfer(BKC, user, rewardAmount);

            // 更新状态
            hasRewarded[user][_year] = true;
            lastUserRewardTime[user] = block.timestamp;

            totalDistributed += rewardAmount;
            usersProcessed++;

            emit RewardDistributed(user, rewardAmount, _year);
        }

        // 4. 如果有用户被奖励，触发批量事件
        if (usersProcessed > 0) {
            emit BatchRewardsDistributed(usersProcessed, totalDistributed, _year);
        } else {
            revert("No users were rewarded in this batch");
        }
    }

    /**
     * @notice 暂停奖励分配
     */
    function pauseRewards() external onlyOwner {
        _pause();
        emit RewardPaused(msg.sender);
    }

    /**
     * @notice 恢复奖励分配
     */
    function unpauseRewards() external onlyOwner {
        _unpause();
        emit RewardUnpaused(msg.sender);
    }

    /**
     * @notice 查询是否暂停
     */
    function isPaused() external view returns (bool) {
        return paused();
    }

    /**
     * @notice 查询多签信息
     */
    function getWithdrawMultiSigInfo() external view returns (address[] memory, uint256, uint256) {
        return (withdrawSigners, withdrawThreshold, withdrawMultiSigNonce);
    }

    /**
     * @notice 查询提款提案数量
     */
    function getWithdrawalProposalCount() external view returns (uint256) {
        return withdrawalProposals.length;
    }

    /**
     * @notice 查询用户奖励状态
     * @param user 用户地址
     * @param year 年份
     */
    function getUserRewardStatus(address user, uint16 year) external view returns (bool, uint256) {
        return (hasRewarded[user][year], lastUserRewardTime[user]);
    }
}
