// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

abstract contract TierSystem {
    function getAllocation(address tokensale, address _contributor) public virtual view returns (uint);
}

abstract contract IKYCRegistry {
    mapping(address => bool) public allowed;
} 

contract Tokensale is Ownable, Pausable {
    
    using SafeERC20 for IERC20;

    address public tokenAddress;    
    
    uint256 public totalTokensSold; 
    uint256 public totalStableReceived;
    
    uint256 public maxCapInStable;  

    uint256 public timeLockSeconds;

    uint256 public startTime;       
    uint256 public endTime;      

    address public withdrawAddress;   
    
    IKYCRegistry public kycRegistry;
    TierSystem public tierSystem;
    IERC20 public stableCoin;
    IERC20 public token;
    uint public tokensForSale;
    bool depositedTokens;
    
    struct Contribution {
        uint256 amount;
        uint256 tokens;
        uint256 releasedTokens;
    }

    mapping (address => Contribution) contributions;

    constructor(
                uint _startTime,
                uint _endTime,
                uint _maxCapInStable,
                uint _tokensForSale,
                uint _timeLockSeconds,
                uint _vestingDurationSeconds,
                uint _vestingWidthdrawInterval,
                IERC20 _token,
                address _withdrawAddress,
                TierSystem _tierSystem,
                IKYCRegistry _kycRegistry
                ) {
                         
        
        stableCoin = IERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
        maxCapInStable = _maxCapInStable;
        vestingWidthdrawInterval = _vestingWidthdrawInterval;
        withdrawAddress = _withdrawAddress;
        startTime = _startTime;
        tokensForSale = _tokensForSale;
        endTime   = _endTime;
        kycRegistry = _kycRegistry;
        tierSystem = _tierSystem;
        token = _token;
        timeLockSeconds = _timeLockSeconds;
        vestingDurationSeconds = _vestingDurationSeconds;
    }


    // how many tokens I can buy with 1 BUSD
    function getTokenPrice() view public returns (uint) {
        return tokensForSale / maxCapInStable ;
    }

    // get allocation in stables
    function getAllocation(address user) public view returns (uint) {
        return tierSystem.getAllocation(address(this), user);
    }


    // get available amount in stables
    function getAvailableParticipateAmount(address user) public view returns (uint) {
        
        Contribution memory contrib = contributions[user];
        return getAllocation(user) * (bonusRound ? 2 : 1) - contrib.amount;
    }

    // team should deposit tokens for sale
    function depositTokens() public {
        require(depositedTokens == false, "DONE");
        token.transferFrom(msg.sender, address(this), tokensForSale);
        depositedTokens = true;
    }

    // if somebody sent wrong tokens - help him to recover
    function emergencyWithdrawTokens(address _token, uint _amount) public onlyOwner {
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }

    // is bonus round started
    bool public bonusRound;

    // start bonus round to sell rest of the tokens
    function startBonusRound() public {

        require(endTime < block.timestamp);
        require(totalTokensSold < tokensForSale, "COND2");
        require(vestingStart == 0, "COND3");
        require(bonusRound == false, "COND4");

        bonusRound = true;
    }

    // emergency pause
    function pause() public onlyOwner {
        _pause();
    }

    // unpause the tokensale after emergency is over
    function unpause() public onlyOwner {
        _unpause();
    }

    event Participate(address user, uint amount);

    /**
     * Main function to participate in IDO based on user's tier lavel (won lottery) and passed KYC.
     _amount in stables
     */
    function participate(uint _amountStables) whenNotPaused public {
        
        require(startTime <= block.timestamp, "START");
        
        require(block.timestamp <= endTime || bonusRound, "FINISH");

        require(_amountStables > 0, "AMOUNT");

        require(kycRegistry.allowed(msg.sender), "KYC");

        // get amount in stables
        uint availableToBuyInStables = getAvailableParticipateAmount(msg.sender);
        
        require(availableToBuyInStables > 0, "PA1");

        require(_amountStables <= availableToBuyInStables, "PA2");

        // should be allowed by user
        stableCoin.safeTransferFrom(msg.sender, address(this), _amountStables);

        uint tokensToBuy = _amountStables * getTokenPrice();
        
        Contribution storage contrib = contributions[msg.sender];

        contrib.amount += _amountStables;
        
        contrib.tokens += tokensToBuy;
        
        totalStableReceived += _amountStables;
        
        totalTokensSold += tokensToBuy;

        require(totalTokensSold <= tokensForSale, "OVERFLOW");

        emit Participate(msg.sender, _amountStables);

        if (totalTokensSold == tokensForSale) {
            _finish();
        }


    }

    /**
     * The timestamp when user could withdraw the first token according to vesting schedule
     */
    uint public vestingStart;

    /*
    * Vesting period 
    */
    uint public vestingDurationSeconds;

    /*
    * Withdraw Interval in seconds
    */
    uint public vestingWidthdrawInterval;

    /**
     * @dev Return the status for the IDO for the front-end
     */
    function getStatus(uint currentTimestamp) public view returns (string memory) {
        if (vestingStart > 0) {
            return "vesting";
        }

        if (!bonusRound && currentTimestamp > endTime && totalTokensSold < tokensForSale) {
            return "need bonusRound";
        }

        if (startTime > currentTimestamp) {
            return "waiting";
        }

        if (bonusRound) {
            return "bonus";
        }

        return "round 1";
    }
    
    /**
     * @dev Internal Function to start vesting with initial lockup and vesting duration for all participants
       Inspired by https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/finance/VestingWallet.sol for multiple wallets
     */
    function _startVesting() internal {
        
        require(vestingStart == 0, "START");
        vestingStart = block.timestamp + timeLockSeconds;
    }

    /**
     * @dev Internal Function to finish IDO
     */
    function _finish() internal {
        _startVesting();
        
    }

    /**
     * @dev Virtual implementation of the vesting formula. This returns the amount vested, as a function of time, for
     * an asset given its total historical allocation.
     */
    function _vestingSchedule(uint256 totalAllocation, uint64 timestamp) internal view virtual returns (uint256) {
        
        
        if (timestamp < vestingStart) {
            return 0;
        } else if (timestamp > vestingStart + vestingDurationSeconds) {
            return totalAllocation;
        } else {

            uint numberOfPeriods = vestingDurationSeconds / vestingWidthdrawInterval;
            uint allocationPart = totalAllocation / numberOfPeriods;

            uint distributed = (totalAllocation * (timestamp - vestingStart)) / vestingDurationSeconds;

            return distributed - (distributed % allocationPart);
        }

    }

     /**
     * @dev Calculates the amount of tokens that has already vested. Default implementation is a linear vesting curve.
     */
    function vestedAmount(address user, uint64 timestamp) public view virtual returns (uint256) {

        Contribution memory contrib = contributions[user];

        return _vestingSchedule(contrib.tokens, timestamp) ;
    }

    event Released(address user, uint tokens);

    /**
     * @dev User should call this function from the front-end to get vested tokens
     */
    function release() public virtual {

        Contribution storage contrib = contributions[msg.sender];

        uint256 releasable = vestedAmount(msg.sender, uint64(block.timestamp)) - contrib.releasedTokens;
        contrib.releasedTokens += releasable;
        
        emit Released(msg.sender, releasable);
        token.safeTransfer(msg.sender, releasable);
    }
    
    
    
}
