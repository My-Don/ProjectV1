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

contract ServerNodeBackup is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    uint256 public constant BIGNODE = 2000;
    uint256 public constant BASENODE = 500;

    using Counters for Counters.Counter;
    Counters.Counter private _counter;

    address public BKC;
    address public REWARD;

    uint256 public totalPhysicalNodes;
    uint256 public totalNodesSold;

    mapping(address => uint256) public lastUserRewardTime;

    // ==================== 操作多签系统 ====================
    address[] public opSigners;                    // 操作签名者列表
    uint256 public opThreshold;                    // 操作多签阈值
    mapping(address => bool) public isOpSigner;    // 操作签名者映射
    uint256 public opMultiSigNonce;               // 操作多签nonce

    // ==================== 资金提取多签系统 ====================
    address[] public withdrawSigners;              // 提款签名者列表
    uint256 public withdrawThreshold;              // 提款多签阈值
    mapping(address => bool) public isWithdrawSigner; // 提款签名者映射
    uint256 public withdrawMultiSigNonce;          // 提款nonce

    // 提款提案结构
    struct WithdrawalProposal {
        address proposer;          // 提议者
        address token;             // 代币地址
        address payable recipient; // 接收地址
        uint256 amount;            // 提款数量
        uint256 confirmations;     // 确认数量
        bool executed;             // 是否已执行
        uint256 createdAt;         // 创建时间
    }

    // 提款提案列表
    WithdrawalProposal[] public withdrawalProposals;
    // 提款确认记录
    mapping(uint256 => mapping(address => bool)) public withdrawalConfirmations;

    struct NodeInfo {
        string ip;
        string describe;
        string name;
        bool isActive;
        uint8 typeParam;
        uint256 id;
        uint256 capacity;
        uint256 createTime;
        uint256 blockHeight;
    }

    struct configNodeParams {
        address stakeAddress;
        bool isActive;
        uint8 typeParam;
        uint256 id;
        uint256 nodeCapacity;
        uint256 nodeMoney;
        uint256 createTime;
        uint256 blockHeight;
    }

    mapping(address => bool) public whiteList;
    mapping(address => configNodeParams[]) public buyNode;
    mapping(uint256 => configNodeParams[]) public getBuyNodeById;
    mapping(address => NodeInfo[]) public deployNode;
    mapping(address => uint256) public userPhysicalNodes;
    mapping(address => mapping(uint16 => bool)) public hasRewarded;

    modifier onlyEOA() {
        require(msg.sender == tx.origin, "Only EOA");
        _;
    }

    // 操作多签修饰符
    modifier onlyOpMultiSig() {
        require(isOpSigner[msg.sender], "Not authorized: caller is not an operation signer");
        _;
    }

    // 资金提取多签修饰符
    modifier onlyWithdrawMultiSig() {
        require(isWithdrawSigner[msg.sender], "Not authorized: caller is not a withdrawal signer");
        _;
    }

    // 提款提案存在且未执行修饰符
    modifier withdrawalProposalExists(uint256 proposalId) {
        require(proposalId < withdrawalProposals.length, "Withdrawal proposal does not exist");
        require(!withdrawalProposals[proposalId].executed, "Withdrawal proposal already executed");
        _;
    }

    // 提款提案未被该签名者确认修饰符
    modifier notWithdrawConfirmed(uint256 proposalId) {
        require(!withdrawalConfirmations[proposalId][msg.sender], "Already confirmed this withdrawal");
        _;
    }

    event CreateNodeInfo(string indexed ip, string describe, string indexed name, bool isActive, uint8 typeParam, uint256 id, uint256 indexed capacity, uint256 blockTime, uint256 blockHeight);
    event ConfigNodeInfo(address indexed stakeAddress, bool isActive, uint8 typeParam, uint256 id, uint256 indexed capacity, uint256 money, uint256 blockTime, uint256 blockHeight);
    event RewardDistributed(address indexed user, uint256 indexed amount);
    event RewardPaused(address indexed admin);
    event RewardUnpaused(address indexed admin);
    event RewardAttempt(address indexed user, uint16 year, uint256 timestamp);

    // 操作多签事件
    event OpSignerAdded(address indexed signer);
    event OpSignerRemoved(address indexed signer);
    event OpThresholdUpdated(uint256 newThreshold);
    event OpMultiSigInitialized(address[] signers, uint256 threshold);

    // 资金提取多签事件
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

    function getSalt(address owner, uint256 number) internal view returns(bytes32 _salt) {
        _salt = keccak256(abi.encodePacked(number, block.number, address(this), owner, blockhash(block.timestamp - 1)));
    }

    function create(bytes32 salt_, bytes memory byteCode) internal returns (address addr) {
        assembly {
            addr := create2(0, add(byteCode, 0x20), mload(byteCode), salt_)
        }
    }

    function initialize(address _owner, address _rewardCalculator, address[] memory _signers, uint256 _threshold) public initializer {
        __Ownable_init(msg.sender);
        transferOwnership(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();
        require(_rewardCalculator != address(0), "Reward calculator address is zero");
        REWARD = _rewardCalculator;
        require(opSigners.length == 0, "Operation MultiSig already initialized");
        require(_threshold > 0, "Threshold must be > 0");
        require(_threshold <= _signers.length, "Threshold exceeds signers count");

        for (uint i = 0; i < _signers.length; i++) {
            require(_signers[i] != address(0), "Invalid signer address");
            require(!isOpSigner[_signers[i]], "Signer already exists");
            opSigners.push(_signers[i]);
            isOpSigner[_signers[i]] = true;
            emit OpSignerAdded(_signers[i]);
        }

        opThreshold = _threshold;
        emit OpThresholdUpdated(_threshold);
        emit OpMultiSigInitialized(_signers, _threshold); 

        require(withdrawSigners.length == 0, "Withdrawal MultiSig already initialized");
        require(_threshold > 0, "Threshold must be > 0");
        require(_threshold <= _signers.length, "Threshold exceeds signers count");

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

    // ==================== 操作多签管理 ====================


    // 添加操作签名者（需要操作多签批准）
    function addOpSigner(address _signer) external onlyOpMultiSig {
        require(_signer != address(0), "Invalid address");
        require(!isOpSigner[_signer], "Already a signer");

        opSigners.push(_signer);
        isOpSigner[_signer] = true;
        emit OpSignerAdded(_signer);
    }

    // 移除操作签名者（需要操作多签批准）
    function removeOpSigner(address _signer) external onlyOpMultiSig {
        require(isOpSigner[_signer], "Not a signer");
        require(opSigners.length > opThreshold, "Cannot remove below threshold");

        for (uint i = 0; i < opSigners.length; i++) {
            if (opSigners[i] == _signer) {
                opSigners[i] = opSigners[opSigners.length - 1];
                opSigners.pop();
                break;
            }
        }

        delete isOpSigner[_signer];
        emit OpSignerRemoved(_signer);
    }

    // 更新操作阈值（需要操作多签批准）
    function updateOpThreshold(uint256 _threshold) external onlyOpMultiSig {
        require(_threshold > 0, "Threshold must be > 0");
        require(_threshold <= opSigners.length, "Threshold exceeds signers count");

        opThreshold = _threshold;
        emit OpThresholdUpdated(_threshold);
    }

   
    // ==================== 资金提取多签管理 ====================

    // 添加提款签名者（需要提款多签批准）
    function addWithdrawSigner(address _signer) external onlyWithdrawMultiSig {
        require(_signer != address(0), "Invalid address");
        require(!isWithdrawSigner[_signer], "Already a signer");

        withdrawSigners.push(_signer);
        isWithdrawSigner[_signer] = true;
        emit WithdrawSignerAdded(_signer);
    }

    // 移除提款签名者（需要提款多签批准）
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

    // 更新提款阈值（需要提款多签批准）
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
    function proposeWithdrawal(
        address _token,
        address payable _recipient,
        uint256 _amount
    ) external onlyWithdrawMultiSig returns (uint256 proposalId) {
        require(_token != address(0), "Invalid token address");
        require(_recipient != address(0), "Invalid recipient address");
        require(_amount > 0, "Amount must be > 0");

        // 验证合约有足够余额
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
    function confirmWithdrawal(uint256 proposalId)
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
     * @notice 执行提款提案
     * @param proposalId 提案ID
     */
    function executeWithdrawal(uint256 proposalId)
        external
        withdrawalProposalExists(proposalId)
        nonReentrant
    {
        WithdrawalProposal storage proposal = withdrawalProposals[proposalId];
        require(proposal.confirmations >= withdrawThreshold, "Not enough confirmations");
        require(!proposal.executed, "Already executed");

        proposal.executed = true;

        // 执行代币转账
        bool success = IERC20(proposal.token).transfer(proposal.recipient, proposal.amount);
        require(success, "Token transfer failed");

        emit WithdrawalProposalExecuted(
            proposalId,
            msg.sender,
            proposal.token,
            proposal.recipient,
            proposal.amount
        );
    }

    /**
     * @notice 快速执行提款（需要达到阈值的签名者直接调用）
     * @dev 确认和执行合并为一步
     * @param proposalId 提案ID
     */
    function confirmAndExecuteWithdrawal(uint256 proposalId)
        external
        onlyWithdrawMultiSig
        withdrawalProposalExists(proposalId)
        notWithdrawConfirmed(proposalId)
        nonReentrant
    {
        WithdrawalProposal storage proposal = withdrawalProposals[proposalId];

        // 先确认
        proposal.confirmations += 1;
        withdrawalConfirmations[proposalId][msg.sender] = true;
        emit WithdrawalProposalConfirmed(proposalId, msg.sender);

        // 检查是否达到阈值
        if (proposal.confirmations >= withdrawThreshold && !proposal.executed) {
            proposal.executed = true;

            // 执行转账
            bool success = IERC20(proposal.token).transfer(proposal.recipient, proposal.amount);
            require(success, "Token transfer failed");

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
     * @notice 查询提款提案信息
     * @param proposalId 提案ID
     * @return proposer 提议者地址
     * @return token 代币地址
     * @return recipient 接收地址
     * @return amount 提款数量
     * @return confirmations 确认数量
     * @return executed 是否已执行
     * @return createdAt 创建时间
     */
    function getWithdrawalProposal(uint256 proposalId)
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
        require(proposalId < withdrawalProposals.length, "Proposal does not exist");
        WithdrawalProposal storage p = withdrawalProposals[proposalId];
        return (p.proposer, p.token, p.recipient, p.amount, p.confirmations, p.executed, p.createdAt);
    }

    /**
     * @notice 查询提案确认状态
     * @param proposalId 提案ID
     * @param signer 签名者地址
     * @return 是否已确认
     */
    function hasWithdrawalConfirmed(uint256 proposalId, address signer) external view returns (bool) {
        return withdrawalConfirmations[proposalId][signer];
    }

    // ==================== 原有功能（使用操作多签） ====================

    // 管理员部署奖励合约（需要操作多签）
    // function createRewards() external onlyOwner {
    //     require(REWARD == address(0), "Reward contract already initialized");
    //     require(owner() != address(0), "Owner must be set first");
    //     REWARD = create(getSalt(owner(), opMultiSigNonce), REWARDCALCULATORCODE);
    //     opMultiSigNonce++;
    // }

    // 管理员创建节点（需要操作多签）
    function createNode(NodeInfo[] calldata _nodeInfo) public onlyOwner {
        _counter.increment();
        uint256 length = _nodeInfo.length;
        require(length > 0, "Node information cannot be an empty array.");
        for(uint256 i = 0; i < length; i++){
            deployNode[_msgSender()].push(NodeInfo({
               ip: _nodeInfo[i].ip,
               describe: _nodeInfo[i].describe,
               name: _nodeInfo[i].name,
               isActive: _nodeInfo[i].isActive,
               typeParam: _nodeInfo[i].typeParam,
               id: _counter.current(),
               capacity: _nodeInfo[i].capacity,
               createTime: block.timestamp,
               blockHeight: block.number
            }));

            emit CreateNodeInfo(_nodeInfo[i].ip, _nodeInfo[i].describe, _nodeInfo[i].name, _nodeInfo[i].isActive, _nodeInfo[i].typeParam, _counter.current(), _nodeInfo[i].capacity, block.timestamp, block.number);
        }
    }

    // 配置节点信息 - 普通用户可调用（白名单或owner），不受多签限制
    function configNode(configNodeParams[] calldata _buyNodeInfo) public nonReentrant {
        address from = _msgSender();
        require(owner() == from || whiteList[from], "Only whitelist or Only Owner");
        uint256 length = _buyNodeInfo.length;
        require(length > 0 && length <= 20, "Node information array must be between 1 and 20 items.");

        uint256 physicalNodesToAdd = 0;

        for(uint256 i = 0; i < length; i++){
            uint8 nodeType = _buyNodeInfo[i].typeParam;
            uint256 nodeValue = _buyNodeInfo[i].nodeMoney;
            uint256 physicalNodeCount = 0;

            require(nodeType >= 1 && nodeType <= 4, "Invalid node type");

            // 根据节点类型计算物理节点数量
            if (nodeType == 1) { // 大节点
                physicalNodeCount = 1;
            } else if (nodeType == 2) { // 中节点 (5个中节点=1物理节点)
                physicalNodeCount = _buyNodeInfo[i].nodeCapacity / 5;
            } else if (nodeType == 3) { // 小节点 (20个小节点=1物理节点)
                physicalNodeCount = _buyNodeInfo[i].nodeCapacity / 20;
            } else if (nodeType == 4) { // 商品节点 - 向下取整以提高精度
                physicalNodeCount = nodeValue / 1000000;
            }

            // 检查节点ID唯一性
            require(getBuyNodeById[_buyNodeInfo[i].id].length == 0, "Node ID already exists");

            physicalNodesToAdd += physicalNodeCount;

            buyNode[from].push(configNodeParams({
                stakeAddress: from,
                isActive: _buyNodeInfo[i].isActive,
                typeParam: nodeType,
                id: _buyNodeInfo[i].id,
                nodeCapacity: _buyNodeInfo[i].nodeCapacity,
                nodeMoney: nodeValue,
                createTime: block.timestamp,
                blockHeight: block.number
            }));

            getBuyNodeById[_buyNodeInfo[i].id].push(configNodeParams({
                stakeAddress: from,
                isActive: _buyNodeInfo[i].isActive,
                typeParam: nodeType,
                id: _buyNodeInfo[i].id,
                nodeCapacity: _buyNodeInfo[i].nodeCapacity,
                nodeMoney: nodeValue,
                createTime: block.timestamp,
                blockHeight: block.number
            }));

            emit ConfigNodeInfo(from, _buyNodeInfo[i].isActive, nodeType, _buyNodeInfo[i].id, _buyNodeInfo[i].nodeCapacity, nodeValue, block.timestamp, block.number);
        }

        require(totalPhysicalNodes + physicalNodesToAdd <= BIGNODE, "Exceeds maximum physical nodes limit");

        totalPhysicalNodes += physicalNodesToAdd;
        userPhysicalNodes[from] += physicalNodesToAdd;
        totalNodesSold += physicalNodesToAdd;
    }

    // 配置白名单（需要操作多签）
    function setWhiteList(address user, bool _isTrue) external onlyOpMultiSig {
        whiteList[user] = _isTrue;
    }

    // 管理员充值BKC（需要操作多签）
    function depositToken(uint256 amount) external onlyOpMultiSig {
        require(amount > 0, "amount must be than 0");
        require(IERC20(BKC).allowance(owner(), address(this)) >= amount, "BKC allowance not sufficient");
        TransferHelper.safeTransferFrom(BKC, msg.sender, address(this), amount);
    }

    // 查询合约内的BKC
    function getTokenBalance() external view returns(uint256) {
        return IERC20(BKC).balanceOf(address(this));
    }

    // 检查状态一致性
    function checkStateConsistency() external view returns(bool) {
        return totalPhysicalNodes == totalNodesSold;
    }

    // 根据节点id查询配置记录
    function getConfigNodeInfo(address user, uint256 startId, uint256 endId) external view returns(configNodeParams[] memory) {
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

    // 查询每日奖励统计
    function getDailyRewards(uint16 _year) internal view returns(uint256) {
        (bool success, bytes memory data) = REWARD.staticcall(abi.encodeWithSignature("getYearlyRewardInfo(uint256)", _year));
        require(success && data.length >= 64, "Query quantity failed");
        (uint256 amount, ) = abi.decode(data, (uint256,bool));
        return amount;
    }


    // 分配每日奖励 - 只有管理员可以调用，每个年份内每24小时最多奖励一次
    function configRewards(address user, uint16 _year) public onlyOwner nonReentrant whenNotPaused {
        emit RewardAttempt(user, _year, block.timestamp);
        require(_year >= 1 && _year <= 10, "Invalid year");
        require(!hasRewarded[user][_year] || block.timestamp >= lastUserRewardTime[user] + 24 hours, "User already rewarded this year or within 24 hours");
        require(user != address(0), "Invalid user address");

        uint256 userPhysicalNodeCount = userPhysicalNodes[user];
        require(userPhysicalNodeCount > 0, "User has no physical nodes");

        uint256 totalPhysicalNodeCount = totalNodesSold;

        // 计算有效物理节点总数
        uint256 effectiveTotalNodes = totalPhysicalNodeCount <= BASENODE ? BASENODE : totalPhysicalNodeCount;

        // 获取奖励
        uint256 reward = getDailyRewards(_year);

        // 检查乘法溢出
        require(reward <= type(uint256).max / userPhysicalNodeCount, "Reward calculation would overflow");

        // 先乘后除，避免整数除法精度损失
        uint256 rewardAmount = (reward * userPhysicalNodeCount) / effectiveTotalNodes;

        require(rewardAmount > 0, "Calculated reward amount is zero - check parameters");
        require(rewardAmount <= 1000000 * 1e18, "Reward amount exceeds maximum limit");

        require(IERC20(BKC).balanceOf(address(this)) >= rewardAmount, "Insufficient reward balance");
        TransferHelper.safeTransfer(BKC, user, rewardAmount);

        // 标记已奖励
        hasRewarded[user][_year] = true;

        // 更新用户最后奖励时间
        lastUserRewardTime[user] = block.timestamp;

        emit RewardDistributed(user, rewardAmount);
    }

    // 暂停奖励分配（需要操作多签）
    function pauseRewards() external onlyOpMultiSig {
        _pause();
        emit RewardPaused(msg.sender);
    }

    // 恢复奖励分配（需要操作多签）
    function unpauseRewards() external onlyOpMultiSig {
        _unpause();
        emit RewardUnpaused(msg.sender);
    }

    // 可选：添加查询暂停状态函数
    function isPaused() external view returns (bool) {
        return paused();
    }

    // 查询操作多签信息
    function getOpMultiSigInfo() external view returns (address[] memory, uint256, uint256) {
        return (opSigners, opThreshold, opMultiSigNonce);
    }

    // 查询资金提取多签信息
    function getWithdrawMultiSigInfo() external view returns (address[] memory, uint256, uint256) {
        return (withdrawSigners, withdrawThreshold, withdrawMultiSigNonce);
    }

    // 查询提款提案数量
    function getWithdrawalProposalCount() external view returns (uint256) {
        return withdrawalProposals.length;
    }

    function setBKC(address _bkc) external onlyOwner {
        BKC = _bkc;
    }
}
