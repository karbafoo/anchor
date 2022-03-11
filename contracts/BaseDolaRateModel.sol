pragma solidity ^0.5.16;

import "./SafeMath.sol";

interface IFeed {
    function decimals() external view returns (uint8);
    function latestAnswer() external view returns (uint);
}


contract DolaFeed is IFeed {

    function decimals() public view returns(uint8) {
        return 18;
    }

    function latestAnswer() public view returns (uint) {
        return 1 ether;
    }

}
/**
  * @title Logic for Compound's JumpRateModel Contract V2.
  * @author Compound (modified by Dharma Labs, refactored by Arr00)
  * @notice Version 2 modifies Version 1 by enabling updateable parameters.
  */
contract BaseJumpRateModelV2 {
    using SafeMath for uint;

    event NewInterestParams(uint baseRatePerBlock, uint multiplierPerBlock, uint jumpMultiplierPerBlock, uint kink);

    /**
     * @notice The address of the owner, i.e. the Timelock contract, which can update parameters directly
     */
    address public owner;

    /**
     * @notice The approximate number of blocks per year that is assumed by the interest rate model
     */
    uint public constant blocksPerYear = 2102400;

    /**
     * @notice The multiplier of utilization rate that gives the slope of the interest rate
     */
    uint public multiplierPerBlock;

    /**
     * @notice The base interest rate which is the y-intercept when utilization rate is 0
     */
    uint public baseRatePerBlock;

    /**
     * @notice The multiplierPerBlock after hitting a specified utilization point
     */
    uint public jumpMultiplierPerBlock;

    /**
     * @notice The utilization point at which the jump multiplier is applied
     */
    uint public kink;

    /**
     * @notice  The depeg threshold. [0] = min, [1] = max
     */
    DolaFeed dolaFeed;

    /**
     * @notice  The depeg threshold. [0] = min, [1] = max
     */
    uint[2] depegThreshold = [0,0];

    /**
     * @notice The range of borrow rate. [0] = min, [1] = max
     */
    uint[2] rateRange = [0,0];

    /**
     * @notice The based borrow rate
     */
    uint baseRate; 
    
    /**
     * @notice The current borrow rate
     */
    uint currentRate;

    /**
     * @notice The borrow rate step amount
     */
    uint rateStep;

    /**
     * @notice The minimum time between each update
     */
    uint updateRateInterval;
    /**
     * @notice The timestmap for the latest update
     */
    uint lastUpdateTimestamp;
    /**
     * @notice Construct an interest rate model
     * @param baseRatePerYear The approximate target base APR, as a mantissa (scaled by 1e18)
     * @param multiplierPerYear The rate of increase in interest rate wrt utilization (scaled by 1e18)
     * @param jumpMultiplierPerYear The multiplierPerBlock after hitting a specified utilization point
     * @param kink_ The utilization point at which the jump multiplier is applied
     * @param owner_ The address of the owner, i.e. the Timelock contract (which has the ability to update parameters directly)
     */
    constructor(uint baseRatePerYear, uint multiplierPerYear, uint jumpMultiplierPerYear, uint kink_,
                 uint baseRate, uint currentRate, uint rateStep, uint[2] memory depegThreshold, uint[2] memory rateRange, uint updateRateInterval,
                 address dolaFeed_, address owner_) internal {
        owner = owner_;
        dolaFeed = DolaFeed(dolaFeed_);
        updateDolaParams(baseRate, currentRate, rateStep, depegThreshold, rateRange, updateRateInterval);
        updateJumpRateModelInternal(baseRatePerYear,  multiplierPerYear, jumpMultiplierPerYear, kink_);
    }

    /**
     * @notice Update the parameters of the interest rate model (only callable by owner, i.e. Timelock)
     * @param baseRatePerYear The approximate target base APR, as a mantissa (scaled by 1e18)
     * @param multiplierPerYear The rate of increase in interest rate wrt utilization (scaled by 1e18)
     * @param jumpMultiplierPerYear The multiplierPerBlock after hitting a specified utilization point
     * @param kink_ The utilization point at which the jump multiplier is applied
     */
    function updateJumpRateModel(uint baseRatePerYear, uint multiplierPerYear, uint jumpMultiplierPerYear, uint kink_) external {
        require(msg.sender == owner, "only the owner may call this function.");

        updateJumpRateModelInternal(baseRatePerYear, multiplierPerYear, jumpMultiplierPerYear, kink_);
    }

    /**
     * @notice Calculates the utilization rate of the market: `borrows / (cash + borrows - reserves)`
     * @param cash The amount of cash in the market
     * @param borrows The amount of borrows in the market
     * @param reserves The amount of reserves in the market (currently unused)
     * @return The utilization rate as a mantissa between [0, 1e18]
     */
    function utilizationRate(uint cash, uint borrows, uint reserves) public pure returns (uint) {
        // Utilization rate is 0 when there are no borrows
        if (borrows == 0) {
            return 0;
        }

        return borrows.mul(1e18).div(cash.add(borrows).sub(reserves));
    }

    /**
     * @notice Calculates the current borrow rate per block, with the error code expected by the market
     * @param cash The amount of cash in the market
     * @param borrows The amount of borrows in the market
     * @param reserves The amount of reserves in the market
     * @return The borrow rate percentage per block as a mantissa (scaled by 1e18)
     */
    function getBorrowRateInternal(uint cash, uint borrows, uint reserves) internal view returns (uint) {
        uint util = utilizationRate(cash, borrows, reserves);

        if (util <= kink) {
            return util.mul(multiplierPerBlock).div(1e18).add(baseRatePerBlock);
        } else {
            uint normalRate = kink.mul(multiplierPerBlock).div(1e18).add(baseRatePerBlock);
            uint excessUtil = util.sub(kink);
            return excessUtil.mul(jumpMultiplierPerBlock).div(1e18).add(normalRate);
        }
    }

    /**
     * @notice Calculates the current supply rate per block
     * @param cash The amount of cash in the market
     * @param borrows The amount of borrows in the market
     * @param reserves The amount of reserves in the market
     * @param reserveFactorMantissa The current reserve factor for the market
     * @return The supply rate percentage per block as a mantissa (scaled by 1e18)
     */
    function getSupplyRate(uint cash, uint borrows, uint reserves, uint reserveFactorMantissa) public view returns (uint) {
        uint oneMinusReserveFactor = uint(1e18).sub(reserveFactorMantissa);
        uint borrowRate = getBorrowRateInternal(cash, borrows, reserves);
        uint rateToPool = borrowRate.mul(oneMinusReserveFactor).div(1e18);
        return utilizationRate(cash, borrows, reserves).mul(rateToPool).div(1e18);
    }

    /**
     * @notice Internal function to update the parameters of the interest rate model
     * @param baseRatePerYear The approximate target base APR, as a mantissa (scaled by 1e18)
     * @param multiplierPerYear The rate of increase in interest rate wrt utilization (scaled by 1e18)
     * @param jumpMultiplierPerYear The multiplierPerBlock after hitting a specified utilization point
     * @param kink_ The utilization point at which the jump multiplier is applied
     */
    function updateJumpRateModelInternal(uint baseRatePerYear, uint multiplierPerYear, uint jumpMultiplierPerYear, uint kink_) internal {
        baseRatePerBlock = baseRatePerYear.div(blocksPerYear);
        multiplierPerBlock = (multiplierPerYear.mul(1e18)).div(blocksPerYear.mul(kink_));
        jumpMultiplierPerBlock = jumpMultiplierPerYear.div(blocksPerYear);
        kink = kink_;
    }
    /**
     * @notice Internal function to update the parameters of the dola interest rate model
     * @param baseRate
     * @param currentRate
     * @param rateStep 
     * @param depegThreshold 
     * @param rateRange 
     * @param updateRateInterval 
     */
    function updateDolaParams(uint baseRate, uint currentRate, uint rateStep, uint[2] memory depegThreshold, uint[2] memory rateRange, uint updateRateInterval) public {
        require(msg.sender == owner, "only the owner may call this function.");
        baseRate = baseRate;
        currentRate = currentRate;
        rateStep = rateStep;
        depegThreshold = depegThreshold;
        rateRange = rateRange;
        updateRateInterval = updateRateInterval;
    }
        
 
    function updateRate() public returns (bool) {
        if(lastUpdateTimestamp + updateRateInterval < block.timestamp){
            lastUpdateTimestamp = block.timestamp;

            uint dolaPrice = dolaFeed.latestAnswer();

            if(dolaPrice < depegThreshold[0]){
                // If DOLA price is under a negativeDepegThreshold price,
                //  increase the borrow rate by a fixed value rateStep up 
                //  to a maximum maxRate.
                if(currentRate < rateRange[1]){
                    currentRate += rateStep;
                    if(currentRate > rateRange[1]){
                        currentRate = rateRange[1];
                    }
                }
            }
            else if (dolaPrice > depegThreshold[1]){
                // If DOLA price is above a positiveDepegThreshold price, 
                // decrease the borrow rate by the same rateStep down
                //  to a minimum minRate.
                if(currentRate > rateRange[0]){
                    currentRate -= rateStep;
                    if(currentRate < rateRange[0]){
                        currentRate = rateRange[0];
                    }
                }
            }
            else{
                // If DOLA price is between the two thresholds AND borrow rate is
                //  not equal to baseRate, decrease or increase the borrow rate to 
                //  the direction of baseRate by rateStep e.g. if the borrow rate is 
                //  higher than baseRate, the borrow rate would decrease by rateStep 
                //  on each function call until it reaches baseRate.
                if(currentRate + rateStep < baseRate){
                    currentRate += rateStep;
                }
                else if(currentRate - rateStep > baseRate){
                    currentRate -= rateStep;
                }
            }
            return true;
        }
        return false;
    }

    function getDolaRate() returns (uint){
        return currentRate;
    }
}
