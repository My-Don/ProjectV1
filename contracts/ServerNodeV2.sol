// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@uniswap/lib/contracts/libraries/TransferHelper.sol";

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

/**
 * @title ServerNodeBackup
 * @notice 服务器节点管理合约
 * @dev 可升级的, 节点创建、分配节点、奖励、多签提款、白名单控制等功能
 */
contract ServerNodeBackup is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    // ====== 常量配置 ======
    uint256 public constant BIGNODE = 2000; // 最大物理节点数量
    uint256 public constant BASENODE = 500; // 基础节点数量（用于奖励计算）
    uint256 public constant MAX_WHITELIST = 3; // 白名单最大数量
    uint256 public constant DEFAULT_CAPACITY = 1_000_000; // 每个节点的默认容量（100万）
    uint256 public constant MAX_NODE_CAPACITY = 10_000_000; // 节点最大容量
    uint256 public constant SECONDS_PER_DAY = 86400; // 每天的秒数
    uint256 private constant SCALE = 1e6; // 精度缩放因子，用于计算等效值

    // ====== 核心状态变量 ======
    using Counters for Counters.Counter;
    Counters.Counter private _counter; // 节点ID计数器

    address private BKC; // BKC代币地址
    address private REWARD; // 奖励计算器地址
    address private STAKEREWARDADDR; // 质押奖励地址

    uint256 public totalPhysicalNodesEquivalent; // 总物理节点等效值（已缩放）
    NodeInfo[] public deployNode; // 所有部署的节点信息数组

    mapping(address => uint256) public userPhysicalNodesEquivalent; // 用户物理节点等效值（已缩放）
    mapping(address => mapping(uint16 => uint256)) public lastRewardDay; // 用户每年最后领取奖励的日期

    // ====== 多签提款系统 ======
    address[] private withdrawSigners; // 多签签名人列表
    uint256 private withdrawThreshold; // 提款所需的最小确认数
    mapping(address => bool) private isWithdrawSigner; // 是否为签名人

    WithdrawalProposal[] private withdrawalProposals; // 提款提案数组
    mapping(uint256 => mapping(address => bool)) private withdrawalConfirmations; // 提案确认记录

    // 提款提案结构：记录谁提议、转给谁、转多少
    struct WithdrawalProposal {
        address proposer; // 提案人
        address token; // 代币地址
        address payable recipient; // 收款人
        uint256 amount; // 金额
        uint256 confirmations; // 确认数
        bool executed; // 是否已执行
        uint256 createdAt; // 创建时间
    }

    // ====== 节点信息结构 ======
    struct NodeInfo {
        string ip; // IP地址
        string describe; // 描述
        string name; // 节点名称
        bool isActive; // 是否激活
        uint8 typeParam; // 节点类型参数
        uint256 id; // 节点ID
        uint256 capacity; // 节点容量
        uint256 createTime; // 创建时间
        uint256 blockHeight; // 创建时的区块高度
    }

    // ====== 组合分配结构 ======
    // 用于组合分配：中节点+小节点+商品（总金额不超过100万）
    struct NodeCombination {
        uint8 mediumNodes; // 中节点数量（每个20万）
        uint8 smallNodes; // 小节点数量（每个5万）
        uint256 commodity; // 商品金额（1-100万之间）
    }

    // 分配记录：记录每次分配的详细信息
    struct AllocationRecord {
        uint256 timestamp; // 分配时间
        address user; // 用户地址
        address stakeAddress; // 质押地址
        uint8 nodeType; // 节点类型（1=大节点，2=中节点，3=小节点，4=商品）
        uint256 amount; // 分配金额
        uint256 nodeId; // 关联的节点ID
    }

    // ====== 批量分配结构 ======
    struct Allocation {
        address user; // 用户地址
        address stakeAddress; // 质押地址
        uint8 nodeType; // 节点类型
        uint256 quantity; // 数量（用于大/中/小节点）
        uint256 amount; // 金额（用于商品）
    }

    // ====== 白名单 ======
    mapping(address => bool) public whiteList; // 白名单映射
    uint256 public currentWhitelistCount; // 当前白名单数量

    // ====== 容量与分配记录 ======
    mapping(uint256 => uint256) public nodeRemainingCapacity; // 节点剩余容量
    mapping(uint256 => bool) public isNodeAllocatedAsBig; // 节点是否已被分配为大节点（整机独占）

    mapping(address => AllocationRecord[]) public userAllocationRecords; // 用户的分配记录
    mapping(uint256 => AllocationRecord[]) public nodeAllocationRecords; // 节点的分配记录

    bool public pausedNodeAllocation; // 节点分配是否暂停
    bool public pausedNodeAllocationReward; // 节点分配奖励是否暂停

    // ====== IP 唯一性 ======
    mapping(bytes32 => bool) private _usedIPs; // 已使用的IP地址（用哈希存储）

    // 只有多签签名人才能调用
    modifier onlyWithdrawMultiSig() {
        require(isWithdrawSigner[msg.sender], "Not authorized");
        _;
    }

    // 检查提款提案是否存在且未执行
    modifier withdrawalProposalExists(uint256 proposalId) {
        require(
            proposalId < withdrawalProposals.length,
            "Proposal does not exist"
        );
        require(!withdrawalProposals[proposalId].executed, "Already executed");
        _;
    }

    // 检查是否已确认过该提案
    modifier notWithdrawConfirmed(uint256 proposalId) {
        require(
            !withdrawalConfirmations[proposalId][msg.sender],
            "Already confirmed"
        );
        _;
    }

    // 只有管理员或白名单用户才能调用
    modifier onlyAllocationAuthorized() {
        require(
            msg.sender == owner() || whiteList[msg.sender],
            "Only owner or whitelist"
        );
        _;
    }

    // 节点分配未暂停时才能调用
    modifier whenAllocationNotPaused() {
        require(!pausedNodeAllocation, "Node allocation is paused");
        _;
    }

    // 节点分配奖励未暂停时才能调用
    modifier whenNodeAllocationRewardNotPaused() {
        require(!pausedNodeAllocationReward, "Node allocation reward is paused");
        _;
    }

    // ====== 事件 ======
    event CreateNodeInfo(
        string indexed ip,
        string describe,
        string indexed name,
        bool isActive,
        uint8 typeParam,
        uint256 id,
        uint256 indexed capacity,
        uint256 blockTime,
        uint256 blockHeight
    );
    event RewardDistributed(
        address indexed user,
        uint256 indexed amount,
        uint16 year
    );
    event RewardPaused(address indexed admin);
    event RewardUnpaused(address indexed admin);
    event BatchRewardsDistributed(
        uint256 indexed totalUsers,
        uint256 indexed totalAmount,
        uint16 year
    );
    event WithdrawSignerAdded(address indexed signer);
    event WithdrawSignerRemoved(address indexed signer);
    event WithdrawThresholdUpdated(uint256 newThreshold);
    event WithdrawMultiSigInitialized(address[] signers, uint256 threshold);
    event WithdrawalProposalSubmitted(
        uint256 indexed proposalId,
        address indexed proposer,
        address indexed token,
        address recipient,
        uint256 amount
    );
    event WithdrawalProposalConfirmed(
        uint256 indexed proposalId,
        address indexed signer
    );
    event WithdrawalProposalExecuted(
        uint256 indexed proposalId,
        address indexed executor,
        address indexed token,
        address recipient,
        uint256 amount
    );
    event NodeAllocated(
        address indexed user,
        address indexed stakeAddress,
        uint8 nodeType,
        uint256 amount,
        uint256 nodeId
    );
    event AllocationPaused(address indexed admin);
    event AllocationUnpaused(address indexed admin);
    event NodeAllocationRewardPaused(address indexed admin);
    event NodeAllocationRewardUnpaused(address indexed admin);
    event WhitelistUpdated(address indexed user, bool added);
    event CombinedNodesAllocated(
        address indexed user,
        address indexed stakeAddress,
        uint8 mediumNodes,
        uint8 smallNodes,
        uint256 commodity,
        uint256 totalAmount
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev 初始化合约
     * @param _owner 合约所有者
     * @param _stakeNodeAddr 质押节点地址
     * @param _rewardCalculator 奖励计算器地址
     * @param _bkc BKC代币地址
     * @param _signers 多签签名人列表
     * @param _threshold 提款所需的最小确认数
     */
    function initialize(
        address _owner,
        address _stakeNodeAddr,
        address _rewardCalculator,
        address _bkc,
        address[] calldata _signers,
        uint256 _threshold
    ) public initializer {
        require(_owner != address(0), "Owner address is zero");
        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();

        require(
            _rewardCalculator != address(0),
            "Reward calculator address is zero"
        );
        require(_bkc != address(0), "Invalid BKC");
        require(_stakeNodeAddr != address(0), "Invalid StakeNodeAddr");
        BKC = _bkc;
        REWARD = _rewardCalculator;
        STAKEREWARDADDR = _stakeNodeAddr;

        require(
            withdrawSigners.length == 0,
            "Withdrawal MultiSig already initialized"
        );
        require(_threshold > 0, "Threshold must be > 0");
        require(
            _threshold <= _signers.length,
            "Threshold exceeds signers count"
        );

        // 初始化多签签名人
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

    // ==================== 多签管理 ====================
    /**
     * @dev 添加多签签名人
     * @param _signer 要添加的签名人地址
     */
    function addWithdrawSigner(address _signer) external onlyWithdrawMultiSig {
        require(_signer != address(0), "Invalid address");
        require(!isWithdrawSigner[_signer], "Already a signer");
        withdrawSigners.push(_signer);
        isWithdrawSigner[_signer] = true;
        emit WithdrawSignerAdded(_signer);
    }

    /**
     * @dev 移除多签签名人
     * @param _signer 要移除的签名人地址
     */
    function removeWithdrawSigner(
        address _signer
    ) external onlyWithdrawMultiSig {
        require(isWithdrawSigner[_signer], "Not a signer");
        require(
            withdrawSigners.length > withdrawThreshold,
            "Cannot remove below threshold"
        );
        // 从数组中移除（用最后一个元素替换，然后删除最后一个）
        for (uint i = 0; i < withdrawSigners.length; i++) {
            if (withdrawSigners[i] == _signer) {
                withdrawSigners[i] = withdrawSigners[
                    withdrawSigners.length - 1
                ];
                withdrawSigners.pop();
                break;
            }
        }
        delete isWithdrawSigner[_signer];
        emit WithdrawSignerRemoved(_signer);
    }

    /**
     * @dev 更新提款阈值（所需的最小确认数）
     * @param _threshold 新的阈值
     */
    function updateWithdrawThreshold(
        uint256 _threshold
    ) external onlyWithdrawMultiSig {
        require(_threshold > 0, "Threshold must be > 0");
        require(
            _threshold <= withdrawSigners.length,
            "Threshold exceeds signers count"
        );
        withdrawThreshold = _threshold;
        emit WithdrawThresholdUpdated(_threshold);
    }

    // ==================== 提款提案 ====================
    /**
     * @dev 创建提款提案
     * @param _token 代币地址（必须是BKC）
     * @param _recipient 收款人地址
     * @param _amount 提款金额
     * @return proposalId 提案ID
     */
    function proposeWithdrawal(
        address _token,
        address payable _recipient,
        uint256 _amount
    ) external onlyWithdrawMultiSig returns (uint256 proposalId) {
        require(_token != address(0) && _token == BKC, "Invalid token address");
        require(_recipient != address(0), "Invalid recipient address");
        require(_amount > 0, "Amount must be > 0");
        uint256 balance = IERC20(_token).balanceOf(address(this));
        require(balance >= _amount, "Insufficient contract balance");

        proposalId = withdrawalProposals.length;
        withdrawalProposals.push(
            WithdrawalProposal({
                proposer: msg.sender,
                token: _token,
                recipient: _recipient,
                amount: _amount,
                confirmations: 0,
                executed: false,
                createdAt: block.timestamp
            })
        );
        emit WithdrawalProposalSubmitted(
            proposalId,
            msg.sender,
            _token,
            _recipient,
            _amount
        );
        return proposalId;
    }

    /**
     * @dev 确认提款提案
     * @param proposalId 提案ID
     */
    function confirmWithdrawal(
        uint256 proposalId
    )
        external
        onlyWithdrawMultiSig
        withdrawalProposalExists(proposalId)
        notWithdrawConfirmed(proposalId)
    {
        WithdrawalProposal storage proposal = withdrawalProposals[proposalId];
        proposal.confirmations += 1;
        withdrawalConfirmations[proposalId][msg.sender] = true;
        emit WithdrawalProposalConfirmed(proposalId, msg.sender);
    }

    /**
     * @dev 执行提款提案（需要达到阈值）
     * @param proposalId 提案ID
     */
    function executeWithdrawal(
        uint256 proposalId
    ) external withdrawalProposalExists(proposalId) nonReentrant {
        WithdrawalProposal storage proposal = withdrawalProposals[proposalId];
        require(
            proposal.confirmations >= withdrawThreshold,
            "Not enough confirmations"
        );
        require(!proposal.executed, "Already executed");
        proposal.executed = true;
        TransferHelper.safeTransfer(
            proposal.token,
            proposal.recipient,
            proposal.amount
        );
        emit WithdrawalProposalExecuted(
            proposalId,
            msg.sender,
            proposal.token,
            proposal.recipient,
            proposal.amount
        );
    }

    /**
     * @dev 确认并执行提款提案（如果确认数刚好达到阈值，则立即执行）
     * @param proposalId 提案ID
     */
    function confirmAndExecuteWithdrawal(
        uint256 proposalId
    )
        external
        onlyWithdrawMultiSig
        withdrawalProposalExists(proposalId)
        notWithdrawConfirmed(proposalId)
        nonReentrant
    {
        WithdrawalProposal storage proposal = withdrawalProposals[proposalId];
        proposal.confirmations += 1;
        withdrawalConfirmations[proposalId][msg.sender] = true;
        emit WithdrawalProposalConfirmed(proposalId, msg.sender);
        // 如果确认数达到阈值，立即执行
        if (proposal.confirmations >= withdrawThreshold && !proposal.executed) {
            proposal.executed = true;
            TransferHelper.safeTransfer(
                proposal.token,
                proposal.recipient,
                proposal.amount
            );
            emit WithdrawalProposalExecuted(
                proposalId,
                msg.sender,
                proposal.token,
                proposal.recipient,
                proposal.amount
            );
        }
    }

    /**
     * @dev 查询提款提案信息
     * @param proposalId 提案ID
     */
    function getWithdrawalProposal(
        uint256 proposalId
    )
        external
        view
        returns (
            address proposer,
            address token,
            address payable recipient,
            uint256 amount,
            uint256 confirmations,
            bool executed,
            uint256 createdAt
        )
    {
        require(
            proposalId < withdrawalProposals.length,
            "Withdrawal proposal does not exist"
        );
        WithdrawalProposal storage p = withdrawalProposals[proposalId];
        return (
            p.proposer,
            p.token,
            p.recipient,
            p.amount,
            p.confirmations,
            p.executed,
            p.createdAt
        );
    }

    /**
     * @dev 查询签名人是否已确认提案
     * @param proposalId 提案ID
     * @param signer 签名人地址
     */
    function hasWithdrawalConfirmed(
        uint256 proposalId,
        address signer
    ) external view returns (bool) {
        return withdrawalConfirmations[proposalId][signer];
    }

    // ==================== 创建节点 ====================
    /**
     * @dev 创建节点（只有管理员可以调用）
     * @param _nodeInfo 节点信息数组
     * @notice 每个节点容量固定为100万，IP地址必须唯一
     */
    function createNode(
        NodeInfo[] calldata _nodeInfo
    ) public onlyOwner nonReentrant {
        require(_nodeInfo.length > 0, "Node information cannot be empty");
        require(
            deployNode.length + _nodeInfo.length <= BIGNODE,
            "Exceeds max physical nodes (2000)"
        );

        for (uint256 i = 0; i < _nodeInfo.length; i++) {
            // 检查IP地址唯一性
            bytes32 ipHash = keccak256(bytes(_nodeInfo[i].ip));
            require(!_usedIPs[ipHash], "IP address must be unique");
            _usedIPs[ipHash] = true;

            // 节点容量固定为100万
            uint256 capacity = DEFAULT_CAPACITY;

            // 生成新的节点ID
            _counter.increment();
            uint256 newId = _counter.current();

            // 保存节点信息
            deployNode.push(
                NodeInfo({
                    ip: _nodeInfo[i].ip,
                    describe: _nodeInfo[i].describe,
                    name: _nodeInfo[i].name,
                    isActive: _nodeInfo[i].isActive,
                    typeParam: _nodeInfo[i].typeParam,
                    id: newId,
                    capacity: capacity,
                    createTime: _nodeInfo[i].createTime == 0
                        ? block.timestamp
                        : _nodeInfo[i].createTime,
                    blockHeight: _nodeInfo[i].blockHeight == 0
                        ? block.number
                        : _nodeInfo[i].blockHeight
                })
            );

            // 初始化节点剩余容量
            nodeRemainingCapacity[newId] = capacity;

            emit CreateNodeInfo(
                _nodeInfo[i].ip,
                _nodeInfo[i].describe,
                _nodeInfo[i].name,
                _nodeInfo[i].isActive,
                _nodeInfo[i].typeParam,
                newId,
                capacity,
                block.timestamp,
                block.number
            );
        }
    }

    // ==================== 分配逻辑 ====================
    /**
     * @dev 批量分配节点
     * @param allocations 分配数组（最多20个）
     * @notice 只有管理员或白名单用户可以调用，分配未暂停时才能调用
     */
    function allocateNodesBatch(
        Allocation[] calldata allocations
    ) external onlyAllocationAuthorized whenAllocationNotPaused nonReentrant {
        require(allocations.length <= 20, "Max 20 allocations per batch");
        for (uint i = 0; i < allocations.length; i++) {
            _processAllocation(
                allocations[i].user,
                allocations[i].stakeAddress,
                allocations[i].nodeType,
                allocations[i].quantity,
                allocations[i].amount
            );
        }
    }

    /**
     * @dev 单次分配节点
     * @param user 用户地址
     * @param stakeAddress 质押地址
     * @param nodeType 节点类型（1=大节点，2=中节点，3=小节点，4=商品）
     * @param quantity 数量（用于大/中/小节点）
     * @param amount 金额（用于商品）
     */
    function allocateNodes(
        address user,
        address stakeAddress,
        uint8 nodeType,
        uint256 quantity,
        uint256 amount
    ) external onlyAllocationAuthorized whenAllocationNotPaused nonReentrant {
        _processAllocation(user, stakeAddress, nodeType, quantity, amount);
    }

    /**
     * @dev 从通用池分配（用于中节点、小节点、商品）
     * @param user 用户地址
     * @param stakeAddress 质押地址
     * @param nodeType 节点类型
     * @param totalAmount 总分配金额
     * @notice 从剩余容量中分配，跳过已被分配为大节点的节点
     */
    function _allocateFromPool(
        address user,
        address stakeAddress,
        uint8 nodeType,
        uint256 totalAmount
    ) internal {
        require(
            totalAmount > 0 && totalAmount <= DEFAULT_CAPACITY,
            "Invalid amount"
        );
        uint256 allocated = 0;

        // 遍历所有物理节点，从剩余容量中分配
        for (
            uint256 i = 0;
            i < deployNode.length && allocated < totalAmount;
            i++
        ) {
            uint256 nodeId = deployNode[i].id;
            
            // 跳过已被整机大节点锁定的节点
            if (isNodeAllocatedAsBig[nodeId]) {
                continue;
            }

            uint256 available = nodeRemainingCapacity[nodeId];
            if (available == 0) {
                continue;
            }

            // 计算本次可从此节点分配的数量
            uint256 toAllocate = totalAmount - allocated > available
                ? available
                : totalAmount - allocated;

            // 扣减剩余容量
            nodeRemainingCapacity[nodeId] -= toAllocate;
            allocated += toAllocate;

            // 记录分配详情
            _recordAllocation(user, stakeAddress, nodeType, toAllocate, nodeId);

            // 如果已分配完，提前退出
            if (allocated >= totalAmount) {
                break;
            }
        }

        // 确保全部分配成功
        require(allocated == totalAmount, "Insufficient capacity in node pool");
    }

    /**
     * @dev 组合分配节点（中节点+小节点+商品，总金额不超过100万）
     * @param user 用户地址
     * @param stakeAddress 质押地址
     * @param combination 组合信息（中节点数量、小节点数量、商品金额）
     * @notice 总金额必须大于0且不超过100万（等于1个大节点的额度）
     * @notice 重要：组合分配必须在同一个节点内完成，不能跨节点分配
     */
    function allocateCombinedNodes(
        address user,
        address stakeAddress,
        NodeCombination calldata combination
    ) external onlyAllocationAuthorized whenAllocationNotPaused {
        require(user != address(0), "Invalid user");
        require(stakeAddress != address(0), "Invalid stake address");

        // 计算总金额：中节点*20万 + 小节点*5万 + 商品金额
        uint256 totalAmount = uint256(combination.mediumNodes) *
            200_000 +
            uint256(combination.smallNodes) *
            50_000 +
            combination.commodity;

        // 总金额必须在1到100万之间
        require(
            totalAmount > 0 && totalAmount <= 1_000_000,
            "Total must be 1~1,000,000"
        );

        // 在单个节点内完成组合分配（不能跨节点）
        _allocateCombinedFromSingleNode(
            user,
            stakeAddress,
            combination,
            totalAmount
        );

        // 更新用户的等效值（按比例计算）
        uint256 equivalent = (totalAmount * SCALE) / DEFAULT_CAPACITY;
        userPhysicalNodesEquivalent[user] += equivalent;
        totalPhysicalNodesEquivalent += equivalent;

        emit CombinedNodesAllocated(
            user,
            stakeAddress,
            combination.mediumNodes,
            combination.smallNodes,
            combination.commodity,
            totalAmount
        );
    }

    /**
     * @dev 从单个节点内完成组合分配（内部函数）
     * @param user 用户地址
     * @param stakeAddress 质押地址
     * @param combination 组合信息
     * @param totalAmount 总金额
     * @notice 确保所有分配都在同一个节点内完成，符合"一个节点的分配不能超过1,000,000元"的需求
     */
    function _allocateCombinedFromSingleNode(
        address user,
        address stakeAddress,
        NodeCombination calldata combination,
        uint256 totalAmount
    ) internal {
        // 查找一个有足够剩余容量的节点（剩余容量≥总金额）
        uint256 targetNodeId = 0;
        bool found = false;
        
        for (uint256 i = 0; i < deployNode.length; i++) {
            uint256 nodeId = deployNode[i].id;
            
            // 跳过已被分配为大节点的节点
            if (isNodeAllocatedAsBig[nodeId]) {
                continue;
            }
            
            uint256 available = nodeRemainingCapacity[nodeId];
            
            // 找到剩余容量≥总金额的节点
            if (available >= totalAmount) {
                targetNodeId = nodeId;
                found = true;
                break;
            }
        }
        
        // 必须找到一个有足够容量的节点
        require(found, "No node has sufficient capacity for combined allocation");
        
        // 在同一个节点内依次分配中节点、小节点、商品
        uint256 remainingCapacity = nodeRemainingCapacity[targetNodeId];
        
        // 分配中节点（每个20万）
        if (combination.mediumNodes > 0) {
            uint256 mediumAmount = uint256(combination.mediumNodes) * 200_000;
            require(remainingCapacity >= mediumAmount, "Insufficient capacity for medium nodes");
            
            for (uint8 i = 0; i < combination.mediumNodes; i++) {
                _recordAllocation(user, stakeAddress, 2, 200_000, targetNodeId);
            }
            nodeRemainingCapacity[targetNodeId] -= mediumAmount;
            remainingCapacity -= mediumAmount;
        }
        
        // 分配小节点（每个5万）
        if (combination.smallNodes > 0) {
            uint256 smallAmount = uint256(combination.smallNodes) * 50_000;
            require(remainingCapacity >= smallAmount, "Insufficient capacity for small nodes");
            
            for (uint8 i = 0; i < combination.smallNodes; i++) {
                _recordAllocation(user, stakeAddress, 3, 50_000, targetNodeId);
            }
            nodeRemainingCapacity[targetNodeId] -= smallAmount;
            remainingCapacity -= smallAmount;
        }
        
        // 分配商品（任意金额）
        if (combination.commodity > 0) {
            require(remainingCapacity >= combination.commodity, "Insufficient capacity for commodity");
            _recordAllocation(user, stakeAddress, 4, combination.commodity, targetNodeId);
            nodeRemainingCapacity[targetNodeId] -= combination.commodity;
        }
    }

    /**
     * @dev 处理单次分配请求（内部函数）
     * @param user 用户地址
     * @param stakeAddress 质押地址
     * @param nodeType 节点类型（1=大节点，2=中节点，3=小节点，4=商品）
     * @param quantity 数量（用于大/中/小节点）
     * @param amount 金额（用于商品）
     */
    function _processAllocation(
        address user,
        address stakeAddress,
        uint8 nodeType,
        uint256 quantity,
        uint256 amount
    ) internal {
        require(user != address(0), "Invalid user");
        require(stakeAddress != address(0), "Invalid stake address");
        require(nodeType >= 1 && nodeType <= 4, "Invalid node type");

        uint256 allocatedCapacity;

        if (nodeType == 4) {
            // 商品分配：金额必须在1到100万之间，数量必须为0
            require(
                amount >= 1 && amount <= 1_000_000,
                "Amount must be 1-1,000,000"
            );
            require(quantity == 0, "Quantity must be 0 for commodity");
            _allocateCommodity(user, stakeAddress, amount);
            allocatedCapacity = amount;
        } else {
            // 大/中/小节点分配：数量必须大于0，金额必须为0
            require(quantity > 0, "Quantity must be > 0");
            require(amount == 0, "Amount must be 0 for node types 1-3");

            if (nodeType == 1) {
                // 大节点：整机独占
                _allocateBigNodes(user, stakeAddress, quantity);
                return;
            } else if (nodeType == 2) {
                // 中节点：每个20万
                _allocateMediumNodes(user, stakeAddress, quantity);
                allocatedCapacity = quantity * 200_000;
            } else if (nodeType == 3) {
                // 小节点：每个5万
                _allocateSmallNodes(user, stakeAddress, quantity);
                allocatedCapacity = quantity * 50_000;
            }
        }

        // 更新等效值（大节点在_allocateBigNodes中已更新，这里跳过）
        if (nodeType != 1) {
            uint256 equivalent = (allocatedCapacity * SCALE) / DEFAULT_CAPACITY;
            userPhysicalNodesEquivalent[user] += equivalent;
            totalPhysicalNodesEquivalent += equivalent;
        }
    }

    /**
     * @dev 分配大节点（整机独占，每个100万）
     * @param user 用户地址
     * @param stakeAddress 质押地址
     * @param quantity 要分配的大节点数量
     * @notice 只能分配typeParam=1且未被分配且剩余容量为100万的节点
     */
    function _allocateBigNodes(
        address user,
        address stakeAddress,
        uint256 quantity
    ) internal {
        uint256 allocated = 0;
        for (uint i = 0; i < deployNode.length && allocated < quantity; i++) {
            uint256 nodeId = deployNode[i].id;
            // 检查：节点类型为1，未被分配为大节点，剩余容量为100万
            if (
                deployNode[i].typeParam == 1 &&
                !isNodeAllocatedAsBig[nodeId] &&
                nodeRemainingCapacity[nodeId] == DEFAULT_CAPACITY
            ) {
                uint256 capacity = deployNode[i].capacity;
                // 标记节点已被分配为大节点，剩余容量设为0
                isNodeAllocatedAsBig[nodeId] = true;
                nodeRemainingCapacity[nodeId] = 0;

                // 记录分配
                _recordAllocation(user, stakeAddress, 1, capacity, nodeId);

                // 更新等效值
                uint256 equivalent = (capacity * SCALE) / DEFAULT_CAPACITY;
                userPhysicalNodesEquivalent[user] += equivalent;
                totalPhysicalNodesEquivalent += equivalent;

                allocated++;
            }
        }
        require(
            allocated == quantity,
            "Insufficient available big nodes (type=1 and unallocated)"
        );
    }

    /**
     * @dev 分配中节点（每个20万）
     * @param user 用户地址
     * @param stakeAddress 质押地址
     * @param quantity 要分配的中节点数量
     * @notice 从剩余容量≥20万的节点中分配，一个节点可以分配多个中节点
     */
    function _allocateMediumNodes(
        address user,
        address stakeAddress,
        uint256 quantity
    ) internal {
        uint256 remaining = quantity;
        uint256 requiredCapacity = 200_000; // 每个中节点需要20万容量

        for (uint i = 0; i < deployNode.length && remaining > 0; i++) {
            uint256 nodeId = deployNode[i].id;
            
            // 跳过已被分配为大节点的节点
            if (isNodeAllocatedAsBig[nodeId]) {
                continue;
            }
            
            uint256 available = nodeRemainingCapacity[nodeId];

            // 如果节点剩余容量≥20万，可以分配中节点
            if (available >= requiredCapacity) {
                // 计算这个节点最多能分配多少个中节点
                uint256 maxFromThisNode = available / requiredCapacity;
                // 实际分配数量 = min(还需要分配的数量, 这个节点能分配的最大数量)
                uint256 allocateCount = remaining > maxFromThisNode
                    ? maxFromThisNode
                    : remaining;

                // 扣减剩余容量
                nodeRemainingCapacity[nodeId] -=
                    allocateCount *
                    requiredCapacity;

                // 为每个中节点创建一条分配记录
                for (uint j = 0; j < allocateCount; j++) {
                    _recordAllocation(
                        user,
                        stakeAddress,
                        2,
                        requiredCapacity,
                        nodeId
                    );
                }

                remaining -= allocateCount;
            }
        }

        require(remaining == 0, "Insufficient capacity for medium nodes");
    }

    /**
     * @dev 分配小节点（每个5万）
     * @param user 用户地址
     * @param stakeAddress 质押地址
     * @param quantity 要分配的小节点数量
     * @notice 从剩余容量≥5万的节点中分配，一个节点可以分配多个小节点
     */
    function _allocateSmallNodes(
        address user,
        address stakeAddress,
        uint256 quantity
    ) internal {
        uint256 remaining = quantity;
        uint256 requiredCapacity = 50_000; // 每个小节点需要5万容量

        for (uint i = 0; i < deployNode.length && remaining > 0; i++) {
            uint256 nodeId = deployNode[i].id;
            
            // 跳过已被分配为大节点的节点
            if (isNodeAllocatedAsBig[nodeId]) {
                continue;
            }
            
            uint256 available = nodeRemainingCapacity[nodeId];

            // 如果节点剩余容量≥5万，可以分配小节点
            if (available >= requiredCapacity) {
                // 计算这个节点最多能分配多少个小节点
                uint256 maxFromThisNode = available / requiredCapacity;
                // 实际分配数量 = min(还需要分配的数量, 这个节点能分配的最大数量)
                uint256 allocateCount = remaining > maxFromThisNode
                    ? maxFromThisNode
                    : remaining;

                // 扣减剩余容量
                nodeRemainingCapacity[nodeId] -=
                    allocateCount *
                    requiredCapacity;

                // 为每个小节点创建一条分配记录
                for (uint j = 0; j < allocateCount; j++) {
                    _recordAllocation(
                        user,
                        stakeAddress,
                        3,
                        requiredCapacity,
                        nodeId
                    );
                }

                remaining -= allocateCount;
            }
        }

        require(remaining == 0, "Insufficient capacity for small nodes");
    }

    /**
     * @dev 分配商品（任意金额，1-100万之间）
     * @param user 用户地址
     * @param stakeAddress 质押地址
     * @param amount 商品金额
     * @notice 从剩余容量中按需分配，可以跨多个节点分配
     */
    function _allocateCommodity(
        address user,
        address stakeAddress,
        uint256 amount
    ) internal {
        uint256 remaining = amount;

        for (uint i = 0; i < deployNode.length && remaining > 0; i++) {
            uint256 nodeId = deployNode[i].id;
            
            // 跳过已被分配为大节点的节点
            if (isNodeAllocatedAsBig[nodeId]) {
                continue;
            }
            
            uint256 available = nodeRemainingCapacity[nodeId];

            // 如果节点剩余容量≥还需要分配的金额，一次性分配完
            if (available >= remaining) {
                nodeRemainingCapacity[nodeId] -= remaining;
                _recordAllocation(user, stakeAddress, 4, remaining, nodeId);
                remaining = 0;
            } else if (available > 0) {
                // 如果节点剩余容量<还需要分配的金额，分配完这个节点的所有剩余容量
                nodeRemainingCapacity[nodeId] -= available;
                _recordAllocation(user, stakeAddress, 4, available, nodeId);
                remaining -= available;
            }
        }

        require(remaining == 0, "Insufficient capacity for commodity");
    }

    /**
     * @dev 记录分配日志（内部函数）
     * @param user 用户地址
     * @param stakeAddress 质押地址
     * @param nodeType 节点类型
     * @param amount 分配金额
     * @param nodeId 节点ID
     * @notice 同时记录到用户分配记录和节点分配记录中
     */
    function _recordAllocation(
        address user,
        address stakeAddress,
        uint8 nodeType,
        uint256 amount,
        uint256 nodeId
    ) internal {
        AllocationRecord memory record = AllocationRecord({
            timestamp: block.timestamp,
            user: user,
            stakeAddress: stakeAddress,
            nodeType: nodeType,
            amount: amount,
            nodeId: nodeId
        });

        // 保存到用户的分配记录
        userAllocationRecords[user].push(record);
        // 保存到节点的分配记录
        nodeAllocationRecords[nodeId].push(record);

        emit NodeAllocated(user, stakeAddress, nodeType, amount, nodeId);
    }

    // ==================== 白名单、暂停、查询、奖励等 ====================
    /**
     * @dev 设置白名单
     * @param user 用户地址
     * @param _isTrue true=添加，false=移除
     * @notice 白名单最多3个，只有管理员可以调用
     */
    function setWhiteList(address user, bool _isTrue) external onlyOwner {
        require(user != address(0), "Invalid user address");
        if (_isTrue) {
            // 添加白名单
            require(
                currentWhitelistCount < MAX_WHITELIST,
                "Max whitelist limit reached"
            );
            require(!whiteList[user], "User already whitelisted");
            whiteList[user] = true;
            currentWhitelistCount++;
        } else {
            // 移除白名单
            if (whiteList[user]) {
                whiteList[user] = false;
                currentWhitelistCount--;
            }
        }
        emit WhitelistUpdated(user, _isTrue);
    }

    /**
     * @dev 暂停节点分配
     * @notice 只有管理员可以调用
     */
    function pauseNodeAllocation() external onlyOwner {
        pausedNodeAllocation = true;
        emit AllocationPaused(msg.sender);
    }

    /**
     * @dev 恢复节点分配
     * @notice 只有管理员可以调用
     */
    function unpauseNodeAllocation() external onlyOwner {
        pausedNodeAllocation = false;
        emit AllocationUnpaused(msg.sender);
    }

    /**
     * @dev 暂停节点分配奖励
     * @notice 只有管理员可以调用，暂停后无法通过configRewards分发奖励
     */
    function pauseNodeAllocationReward() external onlyOwner {
        pausedNodeAllocationReward = true;
        emit NodeAllocationRewardPaused(msg.sender);
    }

    /**
     * @dev 恢复节点分配奖励
     * @notice 只有管理员可以调用
     */
    function unpauseNodeAllocationReward() external onlyOwner {
        pausedNodeAllocationReward = false;
        emit NodeAllocationRewardUnpaused(msg.sender);
    }

    /**
     * @dev 查询用户的所有分配记录
     * @param user 用户地址
     * @return 分配记录数组
     */
    function getUserAllocations(
        address user
    ) external view returns (AllocationRecord[] memory) {
        return userAllocationRecords[user];
    }

    /**
     * @dev 查询节点的所有分配记录
     * @param nodeId 节点ID
     * @return 分配记录数组
     */
    function getNodeAllocations(
        uint256 nodeId
    ) external view returns (AllocationRecord[] memory) {
        return nodeAllocationRecords[nodeId];
    }

    /**
     * @dev 查询节点剩余容量
     * @param nodeId 节点ID
     * @return 剩余容量
     */
    function getNodeRemainingCapacity(
        uint256 nodeId
    ) external view returns (uint256) {
        return nodeRemainingCapacity[nodeId];
    }

    /**
     * @dev 查询当前白名单数量
     * @return 白名单数量
     */
    function getWhitelistCount() external view returns (uint256) {
        return currentWhitelistCount;
    }

    /**
     * @dev 查询节点分配是否暂停
     * @return 是否暂停
     */
    function isNodeAllocationPaused() external view returns (bool) {
        return pausedNodeAllocation;
    }

    /**
     * @dev 查询节点分配奖励是否暂停
     * @return 是否暂停
     */
    function isNodeAllocationRewardPaused() external view returns (bool) {
        return pausedNodeAllocationReward;
    }

    /**
     * @dev 存入代币到合约
     * @param amount 存入金额
     * @notice 只有管理员可以调用，需要先授权
     */
    function depositToken(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(
            IERC20(BKC).allowance(msg.sender, address(this)) >= amount,
            "BKC allowance not sufficient"
        );
        TransferHelper.safeTransferFrom(BKC, msg.sender, address(this), amount);
    }

    /**
     * @dev 查询合约代币余额
     * @return 代币余额
     */
    function getTokenBalance() external view returns (uint256) {
        return IERC20(BKC).balanceOf(address(this));
    }

    /**
     * @dev 查询年度奖励（内部函数）
     * @param _year 年份
     * @return 年度奖励金额
     */
    function getDailyRewards(uint16 _year) internal view returns (uint256) {
        (bool success, bytes memory data) = REWARD.staticcall(
            abi.encodeWithSignature("getYearlyRewardInfo(uint256)", _year)
        );
        require(success && data.length >= 64, "Query reward failed");
        (uint256 amount, ) = abi.decode(data, (uint256, bool));
        return amount;
    }

    /**
     * @dev 配置并分发奖励
     * @param _users 用户地址数组（最多50个）
     * @param _year 年份（1-30）
     * @notice 只有管理员可以调用，奖励未暂停且节点分配奖励未暂停时才能调用
     * @notice 50%奖励转给质押地址，剩余50%按比例分给用户
     */
    function configRewards(
        address[] calldata _users,
        uint16 _year
    ) external onlyOwner nonReentrant whenNotPaused whenNodeAllocationRewardNotPaused {
        require(_users.length > 0, "Users array cannot be empty");
        require(_users.length <= 50, "Too many users, maximum 50 per batch");
        require(_year >= 1 && _year <= 30, "Invalid year");

        // 获取年度每日奖励
        uint256 yearlyReward = getDailyRewards(_year);
        require(yearlyReward > 0, "Reward is zero");

        // 50%转给质押地址
        uint256 stakeRewardAddrAmount = (yearlyReward * 50) / 100;
        TransferHelper.safeTransfer(
            BKC,
            STAKEREWARDADDR,
            stakeRewardAddrAmount
        );
        yearlyReward -= stakeRewardAddrAmount;

        // 计算有效总量（如果总等效值小于基础节点，使用基础节点）
        uint256 effectiveTotal = totalPhysicalNodesEquivalent <
            (BASENODE * SCALE)
            ? (BASENODE * SCALE)
            : totalPhysicalNodesEquivalent;
        require(effectiveTotal > 0, "No physical nodes sold yet");

        uint256 currentDay = block.timestamp / SECONDS_PER_DAY;
        uint256 totalDistributed = 0;
        uint256 usersProcessed = 0;

        // 遍历用户，按比例分发奖励
        for (uint256 i = 0; i < _users.length; i++) {
            address user = _users[i];
            require(user != address(0), "Invalid user address");

            uint256 userEquivalent = userPhysicalNodesEquivalent[user];
            if (userEquivalent == 0) continue; // 用户没有节点，跳过
            if (lastRewardDay[user][_year] >= currentDay) continue; // 今天已领取，跳过

            // 按比例计算奖励
            uint256 rewardAmount = (yearlyReward * userEquivalent) /
                effectiveTotal;
            if (rewardAmount == 0) continue; // 奖励为0，跳过

            // 检查合约余额
            uint256 contractBalance = IERC20(BKC).balanceOf(address(this));
            require(
                contractBalance >= rewardAmount,
                "Insufficient contract balance"
            );

            // 转账奖励
            TransferHelper.safeTransfer(BKC, user, rewardAmount);
            lastRewardDay[user][_year] = currentDay; // 记录领取日期

            totalDistributed += rewardAmount;
            usersProcessed++;
            emit RewardDistributed(user, rewardAmount, _year);
        }

        emit BatchRewardsDistributed(usersProcessed, totalDistributed, _year);
    }

    /**
     * @dev 暂停奖励分发
     * @notice 只有管理员可以调用
     */
    function pauseRewards() external onlyOwner {
        _pause();
        emit RewardPaused(msg.sender);
    }

    /**
     * @dev 恢复奖励分发
     * @notice 只有管理员可以调用
     */
    function unpauseRewards() external onlyOwner {
        _unpause();
        emit RewardUnpaused(msg.sender);
    }

    /**
     * @dev 查询奖励是否暂停
     * @return 是否暂停
     */
    function isPaused() external view returns (bool) {
        return paused();
    }

    // ==================== 查询函数 ====================
    /**
     * @dev 查询多签信息
     * @return 签名人列表和阈值
     */
    function getWithdrawMultiSigInfo()
        external
        view
        returns (address[] memory, uint256)
    {
        return (withdrawSigners, withdrawThreshold);
    }

    /**
     * @dev 查询提款提案数量
     * @return 提案数量
     */
    function getWithdrawalProposalCount() external view returns (uint256) {
        return withdrawalProposals.length;
    }

    /**
     * @dev 查询用户奖励状态
     * @param user 用户地址
     * @param year 年份
     * @return 是否已领取过，最后领取日期
     */
    function getUserRewardStatus(
        address user,
        uint16 year
    ) external view returns (bool, uint256) {
        return (lastRewardDay[user][year] > 0, lastRewardDay[user][year]);
    }
}

