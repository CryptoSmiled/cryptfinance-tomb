// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

// import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
// import "@openzeppelin/contracts/math/SafeMath.sol";

import "./../dependencies/lib/SafeERC20.sol";
import "./../dependencies/Ownable.sol";

// Note that this pool has no minter key of SKULL (rewards).
// Instead, the governance will call SKULL distributeReward method and send reward to this pool at the beginning.
contract SkullGenesisRewardPool is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // governance
    address public operator;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 token; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. SKULL to distribute.
        uint256 lastRewardTime; // Last time that SKULL distribution occurs.
        uint256 accSkullPerShare; // Accumulated SKULL per share, times 1e18. See below.
        bool isStarted; // if lastRewardBlock has passed
    }

    IERC20 public skull;

    // Info of each pool.
    PoolInfo[] public poolInfo;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;

    // The time when SKULL mining starts.
    uint256 public poolStartTime;

    // The time when SKULL mining ends.
    uint256 public immutable poolEndTime;

    // TESTNET
    uint256 public constant TOTAL_REWARDS = 24_000 ether;
    uint256 public constant runningTime = 1 days; // 1 hours
    // END TESTNET

    // // MAINNET
    // uint256 public constant TOTAL_REWARDS = 24_000 ether;
    // uint256 public constant runningTime = 48 hours; // 48 hours
    // // END MAINNET

    uint256 public immutable skullPerSecond;

    //Mapping to store permitted contract users.
    mapping(address => bool) public permittedUsers;

    //Fee allocation variables.
    uint256 public constant FEE = 100;
    uint256 public constant FEE_DENOM = 10_000;

    address[] public feeWallets = [
        // address(0x04b79c851ed1A36549C6151189c79EC0eaBca745), //Non-Native Pool.
        address(0x33A4622B82D4c04a53e170c638B944ce27cffce3), // Dev1.
        address(0x21b42413bA931038f35e7A5224FaDb065d297Ba3), // Dev2.
        address(0x0063046686E46Dc6F15918b61AE2B121458534a5)  // Dev3.
    ];

    uint256[] public feeWeights = [
        // 100,//Non-Native Pool.
        15, // Dev1.
        15, // Dev2.
        70  // Dev3.
    ];

    uint256 public totalFeeWeight;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);

    constructor(
        address _skull,
        uint256 _poolStartTime
    ) public {
        require(block.timestamp < _poolStartTime, "late");
        if (_skull != address(0)) skull = IERC20(_skull);
        poolStartTime = _poolStartTime;
        poolEndTime = poolStartTime + runningTime;
        operator = msg.sender;

        //Calculating the total fee weight.
        totalFeeWeight = 0;
        for (uint256 idx = 0; idx < feeWallets.length; ++idx) {
            totalFeeWeight = totalFeeWeight.add(feeWeights[idx]);
        }

        skullPerSecond = TOTAL_REWARDS.div(runningTime);

    }

    modifier onlyOperator() {
        require(operator == msg.sender, "SkullGenesisPool: caller is not the operator");
        _;
    }

    //Modifier to restrict the types of accounts that can access the pool (Protects against big farmers/External ACs).
    modifier onlyPermittedUser() {
        if (Address.isContract(msg.sender) || tx.origin != msg.sender) {
            require (permittedUsers[msg.sender], "Error: Contract address is not a permitted user");
        }
        _;
    }

    function checkPoolDuplicate(IERC20 _token) internal view {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            require(poolInfo[pid].token != _token, "SkullGenesisPool: existing pool?");
        }
    }

    // Add a new token to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPoint,
        IERC20 _token,
        bool _withUpdate,
        uint256 _lastRewardTime
    ) public onlyOperator {
        checkPoolDuplicate(_token);
        if (_withUpdate) {
            massUpdatePools();
        }
        if (block.timestamp < poolStartTime) {
            // chef is sleeping
            if (_lastRewardTime == 0) {
                _lastRewardTime = poolStartTime;
            } else {
                if (_lastRewardTime < poolStartTime) {
                    _lastRewardTime = poolStartTime;
                }
            }
        } else {
            // chef is cooking
            if (_lastRewardTime == 0 || _lastRewardTime < block.timestamp) {
                _lastRewardTime = block.timestamp;
            }
        }
        bool _isStarted = (_lastRewardTime <= poolStartTime) || (_lastRewardTime <= block.timestamp);
        poolInfo.push(PoolInfo({token: _token, allocPoint: _allocPoint, lastRewardTime: _lastRewardTime, accSkullPerShare: 0, isStarted: _isStarted}));
        if (_isStarted) {
            totalAllocPoint = totalAllocPoint.add(_allocPoint);
        }
    }

    // Update the given pool's SKULL allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint) public onlyOperator {
        massUpdatePools();
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.isStarted) {
            totalAllocPoint = totalAllocPoint.sub(pool.allocPoint).add(_allocPoint);
        }
        pool.allocPoint = _allocPoint;
    }

    // Return accumulate rewards over the given _from to _to block.
    function getGeneratedReward(uint256 _fromTime, uint256 _toTime) public view returns (uint256) {
        if (_fromTime >= _toTime) return 0;
        if (_toTime >= poolEndTime) {
            if (_fromTime >= poolEndTime) return 0;
            if (_fromTime <= poolStartTime) return poolEndTime.sub(poolStartTime).mul(skullPerSecond);
            return poolEndTime.sub(_fromTime).mul(skullPerSecond);
        } else {
            if (_toTime <= poolStartTime) return 0;
            if (_fromTime <= poolStartTime) return _toTime.sub(poolStartTime).mul(skullPerSecond);
            return _toTime.sub(_fromTime).mul(skullPerSecond);
        }
    }

    // View function to see pending SKULL on frontend.
    function pendingSKULL(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accSkullPerShare = pool.accSkullPerShare;
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && tokenSupply != 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _skullReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            accSkullPerShare = accSkullPerShare.add(_skullReward.mul(1e18).div(tokenSupply));
        }
        return user.amount.mul(accSkullPerShare).div(1e18).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        if (tokenSupply == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        if (!pool.isStarted) {
            pool.isStarted = true;
            totalAllocPoint = totalAllocPoint.add(pool.allocPoint);
        }
        if (totalAllocPoint > 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _skullReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            pool.accSkullPerShare = pool.accSkullPerShare.add(_skullReward.mul(1e18).div(tokenSupply));
        }
        pool.lastRewardTime = block.timestamp;
    }

    // Deposit LP tokens.
    function deposit(uint256 _pid, uint256 _amount) public onlyPermittedUser {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 _pending = user.amount.mul(pool.accSkullPerShare).div(1e18).sub(user.rewardDebt);
            if (_pending > 0) {
                safeSkullTransfer(_sender, _pending);
                emit RewardPaid(_sender, _pending);
            }
        }
        if (_amount > 0) {

            pool.token.safeTransferFrom(_sender, address(this), _amount);

            uint256 feeAmount = _amount.mul(FEE).div(FEE_DENOM);
            _amount = _amount.sub(feeAmount);

            distributeFees(feeAmount, pool.token);

            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accSkullPerShare).div(1e18);
        emit Deposit(_sender, _pid, _amount);
    }

    function distributeFees(uint256 _feeAmount, IERC20 _feeToken) internal {
        uint256 remBalance = _feeAmount;
        uint256 feeAmount;

        uint256 length = feeWallets.length;
        for (uint256 idx = 0; idx < length; ++idx) {
            feeAmount = _feeAmount.mul(feeWeights[idx]).div(totalFeeWeight);

            //Bounding check before subtraction.
            if (feeAmount > remBalance) { feeAmount = remBalance; }
            remBalance = remBalance.sub(feeAmount);

            _feeToken.safeTransfer(feeWallets[idx], feeAmount);
        }        
    }

    // Withdraw LP tokens.
    function withdraw(uint256 _pid, uint256 _amount) public {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 _pending = user.amount.mul(pool.accSkullPerShare).div(1e18).sub(user.rewardDebt);
        if (_pending > 0) {
            safeSkullTransfer(_sender, _pending);
            emit RewardPaid(_sender, _pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.token.safeTransfer(_sender, _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accSkullPerShare).div(1e18);
        emit Withdraw(_sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 _amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.token.safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _pid, _amount);
    }

    // Safe SKULL transfer function, just in case a rounding error causes pool to not have enough SKULLs.
    function safeSkullTransfer(address _to, uint256 _amount) internal {
        uint256 _skullBalance = skull.balanceOf(address(this));
        if (_skullBalance > 0) {
            if (_amount > _skullBalance) {
                skull.safeTransfer(_to, _skullBalance);
            } else {
                skull.safeTransfer(_to, _amount);
            }
        }
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    //Sets permitted users allowed to deposit.
    function setPermittedUser(address _user, bool _isPermitted) public onlyOwner {
        require(Address.isContract(_user), "Error: Address is not a contract.");
        permittedUsers[_user] = _isPermitted;
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 amount,
        address to
    ) external onlyOperator {
        require(block.timestamp > poolEndTime + 40 days,  "Error: I dont want your tokens.");
        _token.safeTransfer(to, amount);
    }

}