// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "./interfaces/MathUtil.sol";
import "./interfaces/IStakingProxy.sol";
import "./interfaces/IRewardStaking.sol";
import "./interfaces/BoringMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";


/*
CVX Locking contract for https://www.convexfinance.com/
CVX locked in this contract will be entitled to voting rights for the Convex Finance platform
Based on EPS Staking contract for http://ellipsis.finance/
Based on SNX MultiRewards by iamdefinitelyahuman - https://github.com/iamdefinitelyahuman/multi-rewards

V2:
- change locking mechanism to lock to a future epoch instead of current
- pending lock getter
- relocking allocates weight to the current epoch instead of future,
    thus allows keeping voting weight in the same epoch a lock expires by relocking before a vote begins
- balanceAtEpoch and supplyAtEpoch return proper values for future epochs
- do not allow relocking directly to a new address
*/
contract CvxLockerV2 is ReentrancyGuard, Ownable {

    using BoringMath for uint256;
    using BoringMath224 for uint224;
    using BoringMath112 for uint112;
    using BoringMath32 for uint32;
    using SafeERC20
    for IERC20;

    /* ========== STATE VARIABLES ========== */

    struct Reward {
        bool useBoost;
        uint40 periodFinish;
        uint208 rewardRate;
        uint40 lastUpdateTime;
        uint208 rewardPerTokenStored;
    }
    struct Balances {
        uint112 locked;
        uint112 boosted;
    }
    struct LockedBalance {
        uint112 amount;
        uint112 boosted;
        uint32 unlockTime;
        uint256 lockTier;
        uint256 lockDuration;
        bool isWithdrawn;
    }
    struct EarnedData {
        address token;
        uint256 amount;
    }
    struct Epoch {
        uint224 supply; //epoch boosted supply
        uint32 date; //epoch start date
    }
    struct LockTier {
        uint256 duration;
        uint256 boostRate;
        bool isActive;
    }

    //token constants
    IERC20 public constant stakingToken = IERC20(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B); //cvx
    address public constant cvxCrv = address(0x62B9c7356A2Dc64a1969e19C23e4f579F9810Aa7);

    //rewards
    address[] public rewardTokens;
    mapping(address => Reward) public rewardData;

    // Duration that rewards are streamed over
    uint256 public constant rewardsDuration = 86400 * 7;

    // Duration of lock/earned penalty period
    // uint256 public constant lockDuration = rewardsDuration * 16;

    // reward token -> distributor -> is approved to add rewards
    mapping(address => mapping(address => bool)) public rewardDistributors;

    // user -> reward token -> amount
    mapping(address => mapping(address => uint256)) public userRewardPerTokenPaid;
    mapping(address => mapping(address => uint256)) public rewards;

    //supplies and epochs
    uint256 public lockedSupply;
    uint256 public boostedSupply;
    Epoch[] public epochs;

    //mappings for balance data
    mapping(address => Balances) public balances;
    mapping(address => LockedBalance[]) public userLocks;

    //boost
    address public boostPayment = address(0x1389388d01708118b497f59521f6943Be2541bb7);
    uint256 public maximumBoostPayment = 0;
    uint256 public boostRate = 10000;
    uint256 public nextMaximumBoostPayment = 0;
    uint256 public nextBoostRate = 10000;
    uint256 public constant denominator = 10000;

    //staking
    uint256 public minimumStake = 10000;
    uint256 public maximumStake = 10000;
    address public stakingProxy;
    address public constant cvxcrvStaking = address(0x3Fe65692bfCD0e6CF84cB1E7d24108E434A7587e);
    uint256 public constant stakeOffsetOnLock = 500; //allow broader range for staking when depositing

    //management
    uint256 public kickRewardPerEpoch = 100;
    uint256 public kickRewardEpochDelay = 4;

    //shutdown
    bool public isShutdown = false;

    //erc20-like interface
    string private _name;
    string private _symbol;
    uint8 private immutable _decimals;

    // lock tiers
    LockTier[] public lockTiers;

    /* ========== CONSTRUCTOR ========== */

    constructor() public Ownable() {
        _name = "Vote Locked Convex Token";
        _symbol = "vlCVX";
        _decimals = 18;

        uint256 currentEpoch = block.timestamp.div(rewardsDuration).mul(rewardsDuration);
        epochs.push(Epoch({
            supply: 0,
            date: uint32(currentEpoch)
        }));

        // 0.25 year, 1x boost
        lockTiers.push(LockTier({
            duration: rewardsDuration * 13,
            boostRate: 10000,
            isActive: true
        }));

        // 0.5 year, 2x boost
        lockTiers.push(LockTier({
            duration: rewardsDuration * 26,
            boostRate: 20000,
            isActive: true
        }));

        // 1 year, 3x boost
        lockTiers.push(LockTier({
            duration: rewardsDuration * 52,
            boostRate: 30000,
            isActive: true
        }));

        // 2 year, 4x boost
        lockTiers.push(LockTier({
            duration: rewardsDuration * 104,
            boostRate: 40000,
            isActive: true
        }));
    }

    function decimals() public view returns (uint8) {
        return _decimals;
    }
    function name() public view returns (string memory) {
        return _name;
    }
    function symbol() public view returns (string memory) {
        return _symbol;
    }
    function version() public view returns(uint256){
        return 2;
    }

    /* ========== ADMIN CONFIGURATION ========== */

    // Add a new reward token to be distributed to stakers
    function addReward(
        address _rewardsToken,
        address _distributor,
        bool _useBoost
    ) public onlyOwner {
        require(rewardData[_rewardsToken].lastUpdateTime == 0);
        require(_rewardsToken != address(stakingToken));
        rewardTokens.push(_rewardsToken);
        rewardData[_rewardsToken].lastUpdateTime = uint40(block.timestamp);
        rewardData[_rewardsToken].periodFinish = uint40(block.timestamp);
        rewardData[_rewardsToken].useBoost = _useBoost;
        rewardDistributors[_rewardsToken][_distributor] = true;
    }

    // Modify approval for an address to call notifyRewardAmount
    function approveRewardDistributor(
        address _rewardsToken,
        address _distributor,
        bool _approved
    ) external onlyOwner {
        require(rewardData[_rewardsToken].lastUpdateTime > 0);
        rewardDistributors[_rewardsToken][_distributor] = _approved;
    }

    //Set the staking contract for the underlying cvx
    function setStakingContract(address _staking) external onlyOwner {
        require(stakingProxy == address(0), "!assign");

        stakingProxy = _staking;
    }

    //set staking limits. will stake the mean of the two once either ratio is crossed
    function setStakeLimits(uint256 _minimum, uint256 _maximum) external onlyOwner {
        require(_minimum <= denominator, "min range");
        require(_maximum <= denominator, "max range");
        require(_minimum <= _maximum, "min range");
        minimumStake = _minimum;
        maximumStake = _maximum;
        updateStakeRatio(0);
    }

    //set boost parameters
    function setBoost(uint256 _max, uint256 _rate, address _receivingAddress) external onlyOwner {
        require(_max < 1500, "over max payment"); //max 15%
        require(_rate < 30000, "over max rate"); //max 3x
        require(_receivingAddress != address(0), "invalid address"); //must point somewhere valid
        nextMaximumBoostPayment = _max;
        nextBoostRate = _rate;
        boostPayment = _receivingAddress;
    }

    //set kick incentive
    function setKickIncentive(uint256 _rate, uint256 _delay) external onlyOwner {
        require(_rate <= 500, "over max rate"); //max 5% per epoch
        require(_delay >= 2, "min delay"); //minimum 2 epochs of grace
        kickRewardPerEpoch = _rate;
        kickRewardEpochDelay = _delay;
    }

    //shutdown the contract. unstake all tokens. release all locks
    function shutdown() external onlyOwner {
        if (stakingProxy != address(0)) {
            uint256 stakeBalance = IStakingProxy(stakingProxy).getBalance();
            IStakingProxy(stakingProxy).withdraw(stakeBalance);
        }
        isShutdown = true;
    }

    //set approvals for staking cvx and cvxcrv
    function setApprovals() external {
        IERC20(cvxCrv).safeApprove(cvxcrvStaking, 0);
        IERC20(cvxCrv).safeApprove(cvxcrvStaking, uint256(-1));

        IERC20(stakingToken).safeApprove(stakingProxy, 0);
        IERC20(stakingToken).safeApprove(stakingProxy, uint256(-1));
    }

    function addBoostTier(uint256 _duration, uint256 _boostRate) external onlyOwner {
        lockTiers.push(LockTier({
            duration: _duration,
            boostRate: _boostRate,
            isActive: true
        }));
    }

    function setBoostTierActive(uint256 _tier, bool _isActive) external onlyOwner {
        lockTiers[_tier].isActive = _isActive;
    }

    /* ========== VIEWS ========== */

    function _rewardPerToken(address _rewardsToken) internal view returns(uint256) {
        if (boostedSupply == 0) {
            return rewardData[_rewardsToken].rewardPerTokenStored;
        }
        return
        uint256(rewardData[_rewardsToken].rewardPerTokenStored).add(
            _lastTimeRewardApplicable(rewardData[_rewardsToken].periodFinish).sub(
                rewardData[_rewardsToken].lastUpdateTime).mul(
                rewardData[_rewardsToken].rewardRate).mul(1e18).div(rewardData[_rewardsToken].useBoost ? boostedSupply : lockedSupply)
        );
    }

    function _earned(
        address _user,
        address _rewardsToken,
        uint256 _balance
    ) internal view returns(uint256) {
        return _balance.mul(
            _rewardPerToken(_rewardsToken).sub(userRewardPerTokenPaid[_user][_rewardsToken])
        ).div(1e18).add(rewards[_user][_rewardsToken]);
    }

    function _lastTimeRewardApplicable(uint256 _finishTime) internal view returns(uint256){
        return Math.min(block.timestamp, _finishTime);
    }

    function lastTimeRewardApplicable(address _rewardsToken) public view returns(uint256) {
        return _lastTimeRewardApplicable(rewardData[_rewardsToken].periodFinish);
    }

    function rewardPerToken(address _rewardsToken) external view returns(uint256) {
        return _rewardPerToken(_rewardsToken);
    }

    function getRewardForDuration(address _rewardsToken) external view returns(uint256) {
        return uint256(rewardData[_rewardsToken].rewardRate).mul(rewardsDuration);
    }

    // Address and claimable amount of all reward tokens for the given account
    function claimableRewards(address _account) external view returns(EarnedData[] memory userRewards) {
        userRewards = new EarnedData[](rewardTokens.length);
        Balances storage userBalance = balances[_account];
        uint256 boostedBal = userBalance.boosted;
        for (uint256 i = 0; i < userRewards.length; i++) {
            address token = rewardTokens[i];
            userRewards[i].token = token;
            userRewards[i].amount = _earned(_account, token, rewardData[token].useBoost ? boostedBal : userBalance.locked);
        }
        return userRewards;
    }

    // Total BOOSTED balance of an account, including unlocked but not withdrawn tokens
    function rewardWeightOf(address _user) view external returns(uint256 amount) {
        return balances[_user].boosted;
    }

    // total token balance of an account, including unlocked but not withdrawn tokens
    function lockedBalanceOf(address _user) view external returns(uint256 amount) {
        return balances[_user].locked;
    }

    //BOOSTED balance of an account which only includes properly locked tokens as of the most recent eligible epoch
    function balanceOf(address _user) view external returns(uint256 amount) {
        LockedBalance[] storage locks = userLocks[_user];

        //start with current boosted amount
        amount = balances[_user].boosted;

        uint256 locksLength = locks.length;
        uint256 currentEpoch = block.timestamp.div(rewardsDuration).mul(rewardsDuration);
        //remove old records only (will be better gas-wise than adding up)
        for (uint i = 0; i < locksLength; i++) {
            if ( (!locks[i].isWithdrawn && locks[i].unlockTime <= block.timestamp) || uint256(locks[i].unlockTime).sub(locks[i].lockDuration) > currentEpoch ) {
                amount = amount.sub(locks[i].boosted);
            }
        }

        return amount;
    }

    //BOOSTED balance of an account which only includes properly locked tokens at the given epoch
    function balanceAtEpochOf(uint256 _epoch, address _user) view external returns(uint256 amount) {
        LockedBalance[] storage locks = userLocks[_user];

        //get timestamp of given epoch index
        uint256 epochTime = epochs[_epoch].date;

        //need to add up since the range could be in the middle somewhere
        //traverse inversely to make more current queries more gas efficient
        for (uint i = locks.length - 1; i + 1 != 0; i--) {
            uint256 lockEpoch = uint256(locks[i].unlockTime).sub(locks[i].lockDuration);
            //lock epoch must be less or equal to the epoch we're basing from.
            if (lockEpoch <= epochTime && !locks[i].isWithdrawn) {
                amount = amount.add(locks[i].boosted);
            }
        }

        return amount;
    }

    //supply of all properly locked BOOSTED balances at most recent eligible epoch
    function totalSupply() view external returns(uint256 supply) {

        uint256 lockDuration = 0;
        for (uint i = 0; i < lockTiers.length; i++) {
            LockTier memory lockTier = lockTiers[i];
            if (lockTier.duration > lockDuration) {
                lockDuration = lockTier.duration;
            }
        }

        uint256 currentEpoch = block.timestamp.div(rewardsDuration).mul(rewardsDuration);
        uint256 cutoffEpoch = currentEpoch.sub(lockDuration);
        uint256 epochindex = epochs.length;

        //do not include next epoch's supply
        if ( uint256(epochs[epochindex - 1].date) > currentEpoch ) {
            epochindex--;
        }

        //traverse inversely to make more current queries more gas efficient
        for (uint i = epochindex - 1; i + 1 != 0; i--) {
            Epoch storage e = epochs[i];
            if (uint256(e.date) <= cutoffEpoch) {
                break;
            }
            supply = supply.add(e.supply);
        }

        return supply;
    }

    //supply of all properly locked BOOSTED balances at the given epoch
    function totalSupplyAtEpoch(uint256 _epoch) view external returns(uint256 supply) {
        uint256 lockDuration = 0;
        for (uint i = 0; i < lockTiers.length; i++) {
            LockTier memory lockTier = lockTiers[i];
            if (lockTier.duration > lockDuration) {
                lockDuration = lockTier.duration;
            }
        }

        uint256 epochStart = uint256(epochs[_epoch].date).div(rewardsDuration).mul(rewardsDuration);
        uint256 cutoffEpoch = epochStart.sub(lockDuration);

        //traverse inversely to make more current queries more gas efficient
        for (uint i = _epoch; i + 1 != 0; i--) {
            Epoch storage e = epochs[i];
            if (uint256(e.date) <= cutoffEpoch) {
                break;
            }
            supply = supply.add(epochs[i].supply);
        }

        return supply;
    }

    //find an epoch index based on timestamp
    function findEpochId(uint256 _time) view external returns(uint256 epoch) {
        uint256 max = epochs.length - 1;
        uint256 min = 0;

        //convert to start point
        _time = _time.div(rewardsDuration).mul(rewardsDuration);

        for (uint256 i = 0; i < 128; i++) {
            if (min >= max) break;

            uint256 mid = (min + max + 1) / 2;
            uint256 midEpochBlock = epochs[mid].date;
            if(midEpochBlock == _time){
                //found
                return mid;
            }else if (midEpochBlock < _time) {
                min = mid;
            } else{
                max = mid - 1;
            }
        }
        return min;
    }


    // Information on a user's locked balances
    function lockedBalances(
        address _user
    ) view external returns(
        uint256 total,
        uint256 unlockable,
        uint256 locked,
        LockedBalance[] memory lockData
    ) {
        LockedBalance[] storage locks = userLocks[_user];
        Balances storage userBalance = balances[_user];
        uint256 idx;
        for (uint i = 0; i < locks.length; i++) {
            if (locks[i].isWithdrawn) {
                if (locks[i].unlockTime > block.timestamp) {
                    if (idx == 0) {
                        lockData = new LockedBalance[](locks.length - i);
                    }
                    lockData[idx] = locks[i];
                    idx++;
                    locked = locked.add(locks[i].amount);
            } else {
                    unlockable = unlockable.add(locks[i].amount);
                }
            }
        }
        return (userBalance.locked, unlockable, locked, lockData);
    }

    //number of epochs
    function epochCount() external view returns(uint256) {
        return epochs.length;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function checkpointEpoch() external {
        _checkpointEpoch();
    }

    //insert a new epoch if needed. fill in any gaps
    function _checkpointEpoch() internal {
        //create new epoch in the future where new non-active locks will lock to
        uint256 nextEpoch = block.timestamp.div(rewardsDuration).mul(rewardsDuration).add(rewardsDuration);
        uint256 epochindex = epochs.length;

        //first epoch add in constructor, no need to check 0 length

        //check to add
        if (epochs[epochindex - 1].date < nextEpoch) {
            //fill any epoch gaps
            while(epochs[epochs.length-1].date != nextEpoch){
                uint256 nextEpochDate = uint256(epochs[epochs.length-1].date).add(rewardsDuration);
                epochs.push(Epoch({
                    supply: 0,
                    date: uint32(nextEpochDate)
                }));
            }

            //update boost parameters on a new epoch
            if(boostRate != nextBoostRate){
                boostRate = nextBoostRate;
            }
            if(maximumBoostPayment != nextMaximumBoostPayment){
                maximumBoostPayment = nextMaximumBoostPayment;
            }
        }
    }

    // Locked tokens cannot be withdrawn for lockDuration and are eligible to receive stakingReward rewards
    function lock(address _account, uint256 _amount, uint256 _spendRatio, uint256 _lockTier) external nonReentrant updateReward(_account) {
        //pull tokens
        stakingToken.safeTransferFrom(msg.sender, address(this), _amount);

        //lock
        _lock(_account, _amount, _spendRatio, _lockTier);
    }

    //lock tokens
    function _lock(address _account, uint256 _amount, uint256 _spendRatio, uint256 _lockTier) internal {
        require(_amount > 0, "Cannot stake 0");
        require(_spendRatio <= maximumBoostPayment, "over max spend");
        require(!isShutdown, "shutdown");
        require(_lockTier < lockTiers.length, "invalid lock tier");

        Balances storage bal = balances[_account];

        // get lock tier
        LockTier memory lockTier = lockTiers[_lockTier];
        require(lockTier.isActive, "lock tier not active");

        //must try check pointing epoch first
        _checkpointEpoch();

        //calc lock and boosted amount
        uint256 spendAmount = _amount.mul(_spendRatio).div(denominator);
        uint256 boostRatio = boostRate.mul(_spendRatio).div(maximumBoostPayment==0?1:maximumBoostPayment);
        uint112 lockAmount = _amount.sub(spendAmount).to112();
        uint256 boostAmount = _amount.add(_amount.mul(boostRatio).div(denominator));
        uint112 boostedAmount = boostAmount.mul(lockTier.boostRate).div(denominator).to112();

        //add user balances
        bal.locked = bal.locked.add(lockAmount);
        bal.boosted = bal.boosted.add(boostedAmount);

        //add to total supplies
        lockedSupply = lockedSupply.add(lockAmount);
        boostedSupply = boostedSupply.add(boostedAmount);

        //add user lock records or add to current
        uint256 lockEpoch = block.timestamp.div(rewardsDuration).mul(rewardsDuration);
 
        uint256 unlockTime = lockEpoch.add(lockTier.duration);

        userLocks[_account].push(LockedBalance({
                amount: lockAmount,
                boosted: boostedAmount,
                unlockTime: uint32(unlockTime),
                lockTier: _lockTier,
                lockDuration: lockTier.duration,
                isWithdrawn: false
            }));

        Epoch storage e = epochs[epochs.length - 1];
        e.supply = e.supply.add(uint224(boostedAmount));

        //send boost payment
        if (spendAmount > 0) {
            stakingToken.safeTransfer(boostPayment, spendAmount);
        }

        //update staking, allow a bit of leeway for smaller deposits to reduce gas
        updateStakeRatio(stakeOffsetOnLock);

        emit Staked(_account, lockEpoch, _amount, lockAmount, boostedAmount);
    }

    // Withdraw all currently locked tokens where the unlock time has passed
    function _processExpiredLocks(address _account, bool _relock, uint256 _spendRatio, address _withdrawTo, uint256[] memory _index) internal updateReward(_account) {
        Balances storage userBalance = balances[_account];

        uint112 locked;
        uint112 boostedAmount;
        
        if (isShutdown) {
            //if time is beyond last lock, can just bundle everything together
            locked = userBalance.locked;
            boostedAmount = userBalance.boosted;
        } else {
            for (uint i = 0; i < _index.length; i++) {
                require(_index[i] < userLocks[_account].length, "Invalid index");
                LockedBalance storage userLock = userLocks[_account][_index[i]];
                require(!userLock.isWithdrawn, "Already withdrawn");
                require(userLock.unlockTime <= block.timestamp, "Not expired");

                userLock.isWithdrawn = true;

                //add to cumulative amounts
                locked = locked.add(userLock.amount);
                boostedAmount = boostedAmount.add(userLock.boosted);

                //relock or return to user
                if (_relock) {
                    _lock(_withdrawTo, userLock.amount, _spendRatio, userLock.lockTier);
                } else {
                    transferCVX(_withdrawTo, userLock.amount, true);
                }
            }
        }
        require(locked > 0, "no exp locks");

        //update user balances and total supplies
        userBalance.locked = userBalance.locked.sub(locked);
        userBalance.boosted = userBalance.boosted.sub(boostedAmount);
        lockedSupply = lockedSupply.sub(locked);
        boostedSupply = boostedSupply.sub(boostedAmount);

        emit Withdrawn(_account, locked, _relock);
    }

    // withdraw expired locks to a different address
    function withdrawExpiredLocksTo(uint256[] memory _index, address _withdrawTo) external nonReentrant {
        require(_index.length > 0, "No index");
        require(_index.length <= userLocks[msg.sender].length, "Invalid index");
        
        _processExpiredLocks(msg.sender, false, 0, _withdrawTo, _index);
    }

    // Withdraw/relock all currently locked tokens where the unlock time has passed
    function processExpiredLocks(uint256[] memory _index) external nonReentrant {
        require(_index.length > 0, "No index");
        require(_index.length <= userLocks[msg.sender].length, "Invalid index");
        
        _processExpiredLocks(msg.sender, true, 0, msg.sender, _index);
    }

    function kickExpiredLocks(address _account, uint256[] memory _index) external nonReentrant onlyOwner {
        require(_index.length > 0, "No index");
        require(_index.length <= userLocks[_account].length, "Invalid index");
        
        _processExpiredLocks(_account, true, 0, _account, _index);
    }

    //pull required amount of cvx from staking for an upcoming transfer
    function allocateCVXForTransfer(uint256 _amount) internal{
        uint256 balance = stakingToken.balanceOf(address(this));
        if (_amount > balance) {
            IStakingProxy(stakingProxy).withdraw(_amount.sub(balance));
        }
    }

    //transfer helper: pull enough from staking, transfer, updating staking ratio
    function transferCVX(address _account, uint256 _amount, bool _updateStake) internal {
        //allocate enough cvx from staking for the transfer
        allocateCVXForTransfer(_amount);
        //transfer
        stakingToken.safeTransfer(_account, _amount);

        //update staking
        if(_updateStake){
            updateStakeRatio(0);
        }
    }

    //calculate how much cvx should be staked. update if needed
    function updateStakeRatio(uint256 _offset) internal {
        if (isShutdown) return;

        //get balances
        uint256 staked = IStakingProxy(stakingProxy).getBalance();
        uint256 total = stakingToken.balanceOf(address(this)).add(staked);
        
        if(total == 0) return;

        //current staked ratio
        uint256 ratio = staked.mul(denominator).div(total);
        //mean will be where we reset to if unbalanced
        uint256 mean = maximumStake.add(minimumStake).div(2);
        // uint256 max = maximumStake.add(_offset);
        // uint256 min = Math.min(minimumStake, minimumStake - _offset);
        if (ratio > maximumStake.add(_offset)) {
            //remove
            uint256 remove = staked.sub(total.mul(mean).div(denominator));
            IStakingProxy(stakingProxy).withdraw(remove);
        } else if (ratio <  Math.min(minimumStake, minimumStake - _offset)) {
            //add
            uint256 increase = total.mul(mean).div(denominator).sub(staked);
            stakingToken.safeTransfer(stakingProxy, increase);
            IStakingProxy(stakingProxy).stake();
        }
    }

    // Claim all pending rewards
    function getReward(address _account, bool _stake) public nonReentrant updateReward(_account) {
        for (uint i; i < rewardTokens.length; i++) {
            address _rewardsToken = rewardTokens[i];
            uint256 reward = rewards[_account][_rewardsToken];
            if (reward > 0) {
                rewards[_account][_rewardsToken] = 0;
                if (_rewardsToken == cvxCrv && _stake) {
                    IRewardStaking(cvxcrvStaking).stakeFor(_account, reward);
                } else {
                    IERC20(_rewardsToken).safeTransfer(_account, reward);
                }
                emit RewardPaid(_account, _rewardsToken, reward);
            }
        }
    }

    // claim all pending rewards
    function getReward(address _account) external{
        getReward(_account,false);
    }


    /* ========== RESTRICTED FUNCTIONS ========== */

    function _notifyReward(address _rewardsToken, uint256 _reward) internal {
        Reward storage rdata = rewardData[_rewardsToken];

        if (block.timestamp >= rdata.periodFinish) {
            rdata.rewardRate = _reward.div(rewardsDuration).to208();
        } else {
            uint256 remaining = uint256(rdata.periodFinish).sub(block.timestamp);
            uint256 leftover = remaining.mul(rdata.rewardRate);
            rdata.rewardRate = _reward.add(leftover).div(rewardsDuration).to208();
        }

        rdata.lastUpdateTime = block.timestamp.to40();
        rdata.periodFinish = block.timestamp.add(rewardsDuration).to40();
    }

    function notifyRewardAmount(address _rewardsToken, uint256 _reward) external updateReward(address(0)) {
        require(rewardDistributors[_rewardsToken][msg.sender]);
        require(_reward > 0, "No reward");

        _notifyReward(_rewardsToken, _reward);

        // handle the transfer of reward tokens via `transferFrom` to reduce the number
        // of transactions required and ensure correctness of the _reward amount
        IERC20(_rewardsToken).safeTransferFrom(msg.sender, address(this), _reward);
        
        emit RewardAdded(_rewardsToken, _reward);

        if(_rewardsToken == cvxCrv){
            //update staking ratio if main reward
            updateStakeRatio(0);
        }
    }

    // Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
    function recoverERC20(address _tokenAddress, uint256 _tokenAmount) external onlyOwner {
        require(_tokenAddress != address(stakingToken), "Cannot withdraw staking token");
        require(rewardData[_tokenAddress].lastUpdateTime == 0, "Cannot withdraw reward token");
        IERC20(_tokenAddress).safeTransfer(owner(), _tokenAmount);
        emit Recovered(_tokenAddress, _tokenAmount);
    }

    /* ========== MODIFIERS ========== */

    modifier updateReward(address _account) {
        {//stack too deep
            Balances storage userBalance = balances[_account];
            uint256 boostedBal = userBalance.boosted;
            for (uint i = 0; i < rewardTokens.length; i++) {
                address token = rewardTokens[i];
                rewardData[token].rewardPerTokenStored = _rewardPerToken(token).to208();
                rewardData[token].lastUpdateTime = _lastTimeRewardApplicable(rewardData[token].periodFinish).to40();
                if (_account != address(0)) {
                    //check if reward is boostable or not. use boosted or locked balance accordingly
                    rewards[_account][token] = _earned(_account, token, rewardData[token].useBoost ? boostedBal : userBalance.locked );
                    userRewardPerTokenPaid[_account][token] = rewardData[token].rewardPerTokenStored;
                }
            }
        }
        _;
    }

    /* ========== EVENTS ========== */
    event RewardAdded(address indexed _token, uint256 _reward);
    event Staked(address indexed _user, uint256 indexed _epoch, uint256 _paidAmount, uint256 _lockedAmount, uint256 _boostedAmount);
    event Withdrawn(address indexed _user, uint256 _amount, bool _relocked);
    event KickReward(address indexed _user, address indexed _kicked, uint256 _reward);
    event RewardPaid(address indexed _user, address indexed _rewardsToken, uint256 _reward);
    event Recovered(address _token, uint256 _amount);
}