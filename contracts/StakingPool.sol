// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";


abstract contract IBEP20 is IERC20 {
    function decimals() public virtual returns (uint);
}

contract StakingPool is Ownable, ReentrancyGuard {
    using SafeERC20 for IBEP20;
    using EnumerableSet for EnumerableSet.AddressSet;

    
    // Whether a limit is set for users
    bool public hasUserLimit;

    // Accrued token per share
    uint256 public accTokenPerShare;

    // The block number when mining ends.
    uint256 public bonusEndTimestamp;

    // The block number when mining starts.
    uint256 public startTimestamp;

    // The block number of the last pool update
    uint256 public lastRewardTimestamp;

    // The pool limit (0 if none)
    uint256 public poolLimitPerUser;

    // tokens created per block.
    uint256 public rewardPerSecond;

    // The precision factor
    uint256 public PRECISION_FACTOR;

    // The reward token
    IBEP20 public rewardToken;

    // The staked token
    IBEP20 public stakedToken;

    // Info of each user that stakes tokens (stakedToken)
    mapping(address => UserInfo) public userInfo;

    // EnumerableSet to extract or calculate length of all stakers from the contract
    EnumerableSet.AddressSet private allStakers;

    struct UserInfo {
        uint256 amount; // How many staked tokens the user has provided
        uint256 rewardDebt; // Reward debt
        uint256 stakeTime;
    }

    event AdminTokenRecovery(address tokenRecovered, uint256 amount);
    event Deposit(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event NewStartAndEndBlocks(uint256 startTimestamp, uint256 endBlock);
    event NewrewardPerSecond(uint256 rewardPerSecond);
    event NewPoolLimit(uint256 poolLimitPerUser);
    event RewardsStop(uint256 blockNumber);
    event WithdrawRequest(address indexed user, uint256 amount);

    // get count of stakers
    function countOfStakers() public view returns (uint) {
        return allStakers.length();
    }

    // get staker address by index
    function stakerAt(uint index) public view returns (address) {
        return allStakers.at(index);
    }

    /*
     * @notice return the information about staking amount and period
     * @param _user: Staking address
     */    
    function getUserStakingInfo(address _user) public view returns (uint[2] memory) {
        uint[2] memory info;
        info[0] =  userInfo[_user].amount;
        info[1] =  userInfo[_user].stakeTime;
        return info;
    } 

    /*
     * @notice Initialize the contract
     * @param _stakedToken: staked token address
     * @param _rewardToken: equal to _stakedToken
     * @param _rewardPerSecond: reward per block (in rewardToken)
     * @param _startTimestamp: start block
     * @param _bonusEndTimestamp: end block
     * @param _poolLimitPerUser: pool limit per user in stakedToken (if any, else 0)
     * @param _admin: admin address with ownership
     */
    constructor(
        IBEP20 _stakedToken,
        uint256 _rewardPerSecond,
        uint256 _startTimestamp,
        uint256 _bonusEndTimestamp,
        uint256 _poolLimitPerUser
    )  {

        stakedToken = _stakedToken;
        rewardToken = _stakedToken;
        rewardPerSecond = _rewardPerSecond;
        startTimestamp = _startTimestamp;
        bonusEndTimestamp = _bonusEndTimestamp;

        if (_poolLimitPerUser > 0) {
            hasUserLimit = true;
            poolLimitPerUser = _poolLimitPerUser;
        }

        uint256 decimalsRewardToken = uint256(rewardToken.decimals());
        require(decimalsRewardToken < 30, "Must be inferior to 30");

        PRECISION_FACTOR = uint256(10**( uint256(30) - decimalsRewardToken ));

        // Set the lastRewardTimestamp as the startTimestamp
        lastRewardTimestamp = startTimestamp;

        // Transfer ownership to the admin address who becomes owner of the contract
    }

    /*
     * @notice Deposit staked tokens and collect reward tokens (if any)
     * @param _amount: amount to withdraw (in rewardToken)
     */
    function deposit(uint256 _amount) external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];

        if (hasUserLimit) {
            require(_amount + user.amount <= poolLimitPerUser, "User amount above limit");
        }

        _updatePool();

        if (user.amount == 0) {
            allStakers.add(msg.sender);

        }

        if (user.amount > 0) {
            uint256 pending = ((user.amount * accTokenPerShare) / PRECISION_FACTOR) - user.rewardDebt;
            if (pending > 0) {
                rewardToken.safeTransfer(address(msg.sender), pending);
            }
        }

        if (_amount > 0) {
            user.amount = user.amount + _amount;
            stakedTokenSupply = stakedTokenSupply + _amount;

            stakedToken.safeTransferFrom(address(msg.sender), address(this), _amount);
        }

        user.rewardDebt = (user.amount * accTokenPerShare) / PRECISION_FACTOR;
        user.stakeTime = block.timestamp;

        emit Deposit(msg.sender, _amount);
    }

    uint constant withdrawStakingTime = 604800; // week in seconds

    // calculate reward and check ability to withdraw
    function getWithdrawableRewardAmount(UserInfo memory user) private view returns (uint) {
        uint256 pending = ((user.amount * accTokenPerShare) / PRECISION_FACTOR) - user.rewardDebt;

        uint tokenBalance  = IERC20(rewardToken).balanceOf(address(this));
        uint rest = tokenBalance - stakedTokenSupply;
        // as far rest can never been negative (<) is not necessary but logically wise it should be explicetelly here
        if (rest <= 0)
            return 0;

        // adjust amount in case when rewards are not deposited
        pending = rest - pending > 0 ? pending : rest;

        return pending;

    }

    // calculate the APR for the front-end in percent (for the whole period)
    function getProfitabilityInPercent() public view returns (uint) {
        return  (rewardPerSecond * (startTimestamp - bonusEndTimestamp) ) * 100 / stakedTokenSupply;
    }

    /*
     * @notice Withdraw staked tokens and collect reward tokens
     * @param _amount: amount to withdraw (in rewardToken)
     */
    function withdraw(uint256 _amount) external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        require(user.amount >= _amount, "Amount to withdraw too high");
        require(user.stakeTime + withdrawStakingTime <= block.timestamp, "TIME");
        
        _updatePool();

        uint256 pending = getWithdrawableRewardAmount(user);

        if (_amount > 0) {
            user.amount = user.amount - _amount;
            
            stakedTokenSupply -=  _amount;
            
            stakedToken.safeTransfer(address(msg.sender), _amount);
            
            
            if (user.amount == 0)
                allStakers.remove(msg.sender);
        
        }

        if (pending > 0) {
            rewardToken.safeTransfer(address(msg.sender), pending);
        }

        user.rewardDebt = (user.amount * accTokenPerShare) / PRECISION_FACTOR;

        emit WithdrawRequest(msg.sender, _amount);
    }

    /*
            Let user staker rewards  
    */
    function stakeRewards() public {

        UserInfo storage user = userInfo[msg.sender];
        
        //require(user.stakeTime + withdrawStakingTime <= block.timestamp, "TIME");
        
        _updatePool();

        uint256 pending = getWithdrawableRewardAmount(user);

        require(pending > 0, "REWARD"); 

        if (user.amount == 0) {
            allStakers.add(msg.sender);
        }

        user.amount += pending;
        stakedTokenSupply += pending;


        user.rewardDebt = (user.amount * accTokenPerShare) / PRECISION_FACTOR;

    }

    /*
     * @notice Withdraw staked tokens without caring about rewards rewards
     * @dev Needs to be for emergency.
     */
    /*
    function emergencyWithdraw() external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        uint256 amountToTransfer = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;

        if (amountToTransfer > 0) {
            stakedToken.safeTransfer(address(msg.sender), amountToTransfer);
            stakedTokenSupply = stakedTokenSupply.sub(amountToTransfer);
        }

        emit EmergencyWithdraw(msg.sender, user.amount);
    }
    */

    /*
     * @notice Stop rewards
     * @dev Only callable by owner. Needs to be for emergency.
     */
    function emergencyRewardWithdraw(uint256 _amount) external onlyOwner {
        rewardToken.safeTransfer(address(msg.sender), _amount);
    }

    /**
     * @notice It allows the admin to recover wrong tokens sent to the contract
     * @param _tokenAddress: the address of the token to withdraw
     * @param _tokenAmount: the number of tokens to withdraw
     * @dev This function is only callable by admin.
     */
    function recoverWrongTokens(address _tokenAddress, uint256 _tokenAmount) external onlyOwner {
        require(_tokenAddress != address(stakedToken), "Cannot be staked token");
        require(_tokenAddress != address(rewardToken), "Cannot be reward token");

        IBEP20(_tokenAddress).safeTransfer(address(msg.sender), _tokenAmount);

        emit AdminTokenRecovery(_tokenAddress, _tokenAmount);
    }

    /*
     * @notice Stop rewards
     * @dev Only callable by owner
     */
    function stopReward() external onlyOwner {
        bonusEndTimestamp = block.timestamp;
    }

    /*
     * @notice Update pool limit per user
     * @dev Only callable by owner.
     * @param _hasUserLimit: whether the limit remains forced
     * @param _poolLimitPerUser: new pool limit per user
     */
    function updatePoolLimitPerUser(bool _hasUserLimit, uint256 _poolLimitPerUser) external onlyOwner {
        require(hasUserLimit, "Must be set");
        if (_hasUserLimit) {
            require(_poolLimitPerUser > poolLimitPerUser, "New limit must be higher");
            poolLimitPerUser = _poolLimitPerUser;
        } else {
            hasUserLimit = _hasUserLimit;
            poolLimitPerUser = 0;
        }
        emit NewPoolLimit(poolLimitPerUser);
    }

    // Just for admin to undrstand how much he needs to send tokens to pay rewards. He should do it once when he created a contract
    function shouldDepositAdmin() public view returns  (uint) {
        return rewardPerSecond * (bonusEndTimestamp - startTimestamp);
    }

    // Should be called before extendStaking to understand how much to add coins to extend the staking duration
    function shouldDepositAdminToExtendStaking(uint duration) public view returns (uint) {
        return rewardPerSecond * duration;
    }

    // Extend the staking duration
    function extendStaking(uint duration) public onlyOwner {
        bonusEndTimestamp += duration;
    }

    /*
     * @notice Update reward per block
     * @dev Only callable by owner.
     * @param _rewardPerSecond: the reward per block
     */
    function updaterewardPerSecond(uint256 _rewardPerSecond) external onlyOwner {
        //require(block.timestamp < startTimestamp, "Pool has started");
        
        rewardPerSecond = _rewardPerSecond;
        emit NewrewardPerSecond(_rewardPerSecond);
    }

    /**
     * @notice It allows the admin to update start and end blocks
     * @dev This function is only callable by owner.
     * @param _startTimestamp: the new start block
     * @param _bonusEndTimestamp: the new end block
     */
    function updateStartAndEndBlocks(uint256 _startTimestamp, uint256 _bonusEndTimestamp) external onlyOwner {
        require(block.timestamp < startTimestamp, "Pool has started");
        require(_startTimestamp < _bonusEndTimestamp, "New startTimestamp must be lower than new endBlock");
        require(block.timestamp < _startTimestamp, "New startTimestamp must be higher than current block");

        startTimestamp = _startTimestamp;
        bonusEndTimestamp = _bonusEndTimestamp;

        // Set the lastRewardTimestamp as the startTimestamp
        lastRewardTimestamp = startTimestamp;

        emit NewStartAndEndBlocks(_startTimestamp, _bonusEndTimestamp);
    }

    uint public stakedTokenSupply;

    /*
     * @notice View function to see pending reward on frontend.
     * @param _user: user address
     * @return Pending reward for a given user
     */
    function pendingReward(address _user) external view returns (uint256) {
        UserInfo storage user = userInfo[_user];
        //uint256 stakedTokenSupply = stakedToken.balanceOf(address(this));
        if (block.timestamp > lastRewardTimestamp && stakedTokenSupply != 0) {
            uint256 multiplier = _getMultiplier(lastRewardTimestamp, block.timestamp);
            uint256 reward = multiplier * rewardPerSecond;
            uint256 adjustedTokenPerShare =
            accTokenPerShare + (reward * PRECISION_FACTOR / stakedTokenSupply);
            return ((user.amount * adjustedTokenPerShare) / PRECISION_FACTOR) - (user.rewardDebt);
        } else {
            return ((user.amount * accTokenPerShare) / PRECISION_FACTOR) - (user.rewardDebt);
        }
    }

    /*
     * @notice Update reward variables of the given pool to be up-to-date.
     */
    function _updatePool() internal {
        if (block.timestamp <= lastRewardTimestamp) {
            return;
        }

        if (stakedTokenSupply == 0) {
            lastRewardTimestamp = block.timestamp;
            return;
        }

        uint256 multiplier = _getMultiplier(lastRewardTimestamp, block.timestamp);
        uint256 reward = multiplier * rewardPerSecond;
        accTokenPerShare = accTokenPerShare + (reward * PRECISION_FACTOR  / stakedTokenSupply);
        lastRewardTimestamp = block.timestamp;
    }

    /*
     * @notice Return reward multiplier over the given _from to _to block.
     * @param _from: block to start
     * @param _to: block to finish
     */
    function _getMultiplier(uint256 _from, uint256 _to) internal view returns (uint256) {
        if (_to <= bonusEndTimestamp) {
            return _to - _from;
        } else if (_from >= bonusEndTimestamp) {
            return 0;
        } else {
            return bonusEndTimestamp -_from;
        }
    }
}
