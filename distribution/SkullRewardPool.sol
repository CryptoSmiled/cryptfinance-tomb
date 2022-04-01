// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

// import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
// import "@openzeppelin/contracts/math/SafeMath.sol";

import "./../dependencies/interfaces/IERC20.sol";
import "./../dependencies/lib/SafeERC20.sol";
import "./../dependencies/lib/SafeMath.sol";

import "./../dependencies/Ownable.sol";

// Note that this pool has no minter key of GRAPE (rewards).
// Instead, the governance will call GRAPE distributeReward method and send reward to this pool at the beginning.
contract GrapeRewardPool is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // governance
    address public operator;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 token; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. Grapes to distribute in the pool.
        uint256 lastRewardTime; // Last time that Grapes distribution occurred.
        uint256 accGrapePerShare; // Accumulated Grapes per share, times 1e18. See below.
        bool isStarted; // if lastRewardTime has passed
    }

    IERC20 public grape;

    // Info of each pool.
    PoolInfo[] public poolInfo;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;

    // The time when GRAPE mining starts.
    uint256 public poolStartTime;

    uint256[] public epochTotalRewards = [10800 ether, 10800 ether];

    // Time when each epoch ends.
    uint256[3] public epochEndTimes;

    // Reward per second for each of 2 epochs (last item is equal to 0 - for sanity).
    uint256[3] public epochGrapePerSecond;

    //Mapping to store permitted contract users.
    mapping(address => bool) public permitted_users;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);

    constructor(address _grape, uint256 _poolStartTime) public {
        require(block.timestamp < _poolStartTime, "late");
        if (_grape != address(0)) grape = IERC20(_grape);

        poolStartTime = _poolStartTime;

        epochEndTimes[0] = poolStartTime + 4 days; // Day 2-5
        epochEndTimes[1] = epochEndTimes[0] + 5 days; // Day 6-10

        epochGrapePerSecond[0] = epochTotalRewards[0].div(4 days);
        epochGrapePerSecond[1] = epochTotalRewards[1].div(5 days);

        epochGrapePerSecond[2] = 0;
        operator = msg.sender;
    }

    modifier onlyOperator() {
        require(operator == msg.sender, "GrapeRewardPool: caller is not the operator");
        _;
    }

    //Modifier to restrict the types of accounts that can access the pool (Protects against big farmers/External ACs).
    modifier onlyPermittedUser() {
        if (Address.isContract(msg.sender) || tx.origin != msg.sender) {
            require (permitted_users[msg.sender], "Error: Contract address is not a permitted user");
        }
        _;
    }

    function checkPoolDuplicate(IERC20 _token) internal view {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            require(poolInfo[pid].token != _token, "GrapeRewardPool: existing pool?");
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
        poolInfo.push(PoolInfo({token: _token, allocPoint: _allocPoint, lastRewardTime: _lastRewardTime, accGrapePerShare: 0, isStarted: _isStarted}));
        if (_isStarted) {
            totalAllocPoint = totalAllocPoint.add(_allocPoint);
        }
    }

    // Update the given pool's GRAPE allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint) public onlyOperator {
        massUpdatePools();
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.isStarted) {
            totalAllocPoint = totalAllocPoint.sub(pool.allocPoint).add(_allocPoint);
        }
        pool.allocPoint = _allocPoint;
    }

    // Return accumulate rewards over the given _fromTime to _toTime.
    function getGeneratedReward(uint256 _fromTime, uint256 _toTime) public view returns (uint256) {
        for (uint8 epochId = 2; epochId >= 1; --epochId) {
            if (_toTime >= epochEndTimes[epochId - 1]) {
                if (_fromTime >= epochEndTimes[epochId - 1]) {
                    return _toTime.sub(_fromTime).mul(epochGrapePerSecond[epochId]);
                }

                uint256 _generatedReward = _toTime.sub(epochEndTimes[epochId - 1]).mul(epochGrapePerSecond[epochId]);
                if (epochId == 1) {
                    return _generatedReward.add(epochEndTimes[0].sub(_fromTime).mul(epochGrapePerSecond[0]));
                }
                for (epochId = epochId - 1; epochId >= 1; --epochId) {
                    if (_fromTime >= epochEndTimes[epochId - 1]) {
                        return _generatedReward.add(epochEndTimes[epochId].sub(_fromTime).mul(epochGrapePerSecond[epochId]));
                    }
                    _generatedReward = _generatedReward.add(epochEndTimes[epochId].sub(epochEndTimes[epochId - 1]).mul(epochGrapePerSecond[epochId]));
                }
                return _generatedReward.add(epochEndTimes[0].sub(_fromTime).mul(epochGrapePerSecond[0]));
            }
        }
        return _toTime.sub(_fromTime).mul(epochGrapePerSecond[0]);
    }

    // View function to see pending GRAPEs on frontend.
    function pendingGRAPE(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accGrapePerShare = pool.accGrapePerShare;
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && tokenSupply != 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _grapeReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            accGrapePerShare = accGrapePerShare.add(_grapeReward.mul(1e18).div(tokenSupply));
        }
        return user.amount.mul(accGrapePerShare).div(1e18).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Expensive!
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
            uint256 _grapeReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            pool.accGrapePerShare = pool.accGrapePerShare.add(_grapeReward.mul(1e18).div(tokenSupply));
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
            uint256 _pending = user.amount.mul(pool.accGrapePerShare).div(1e18).sub(user.rewardDebt);
            if (_pending > 0) {
                safeGrapeTransfer(_sender, _pending);
                emit RewardPaid(_sender, _pending);
            }
        }
        if (_amount > 0) {
            pool.token.safeTransferFrom(_sender, address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accGrapePerShare).div(1e18);
        emit Deposit(_sender, _pid, _amount);
    }

    // Withdraw LP tokens.
    function withdraw(uint256 _pid, uint256 _amount) public {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 _pending = user.amount.mul(pool.accGrapePerShare).div(1e18).sub(user.rewardDebt);
        if (_pending > 0) {
            safeGrapeTransfer(_sender, _pending);
            emit RewardPaid(_sender, _pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.token.safeTransfer(_sender, _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accGrapePerShare).div(1e18);
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

    // Safe grape transfer function, just in case if rounding error causes pool to not have enough Grapes.
    function safeGrapeTransfer(address _to, uint256 _amount) internal {
        uint256 _grapeBal = grape.balanceOf(address(this));
        if (_grapeBal > 0) {
            if (_amount > _grapeBal) {
                grape.safeTransfer(_to, _grapeBal);
            } else {
                grape.safeTransfer(_to, _amount);
            }
        }
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    //Sets permitted users allowed to deposit.
    function setPermittedUser(address _user, bool _isPermitted) public onlyOwner {
        require(Address.isContract(_user), "Error: Address is not a contract.");
        permitted_users[_user] = _isPermitted;
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 amount,
        address to
    ) external onlyOperator {
        require(block.timestamp > epochEndTimes[1] + 40 days,  "Error: I dont want your tokens.");
        _token.safeTransfer(to, amount);
    }

}