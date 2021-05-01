// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";

// Import interfaces for many popular DeFi projects, or add your own!
import "../interfaces/IInterestVault.sol";
import "../interfaces/IBankConfig.sol";

import "../interfaces/IWETH.sol";
import "../interfaces/IMasterChef.sol";
import "../interfaces/IUniswapV2Router02.sol";

interface IInterestVaultToken is IInterestVault, IERC20 {}

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using SafeERC20 for IInterestVaultToken;

    using Address for address;
    using SafeMath for uint256;

    address internal constant wbnb = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant alpaca = 0x8F0528cE5eF7B51152A59745bEfDD91D97091d2F;

    uint256 public pid;
    bool internal isBNB;

    //Used to swap for best price with 1inch swaps
    address public OneInchRouter = 0x11111112542D85B3EF69AE05771c2dCCff4fAa26;

    //We use pancakeswap router for harvest trigger estimations
    IUniswapV2Router02 pancakeswapRouter = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    IERC20 internal constant iALPACA = IERC20(alpaca);
    IMasterChef public constant alpacaChef = IMasterChef(0xA625AB01B08ce023B2a342Dbb12a16f2C8489A8F);
    IInterestVaultToken public interestToken;
    IWETH internal constant iWBNB = IWETH(wbnb);

    //To receive BNB from interest tokens
    receive() external payable {
        require(isBNB, "Strat is not bnb based interest token");
    }

    event Cloned(address indexed clone);

    constructor(
        address _vault,
        address _interestToken,
        uint256 _pid
    ) public BaseStrategy(_vault) {
        _initializeStrat(_interestToken, _pid);
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _interestToken,
        uint256 _pid
    ) external {
        //note: initialise can only be called once. in _initialize in BaseStrategy we have: require(address(want) == address(0), "Strategy already initialized");
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat(_interestToken, _pid);
    }

    function _initializeStrat(address _interestToken, uint256 _pid) internal {
        // You can set these parameters on deployment to whatever you want
        maxReportDelay = 6300;
        profitFactor = 1500;
        debtThreshold = 1_000_000 * 1e18;

        interestToken = IInterestVaultToken(_interestToken);
        require(interestToken.token() == address(want), "Wrong interest token");
        pid = _pid;
        require(alpacaChef.poolInfo(pid).stakeToken == _interestToken, "Wrong pid or interest token for want");
        interestToken.safeApprove(address(alpacaChef), type(uint256).max);
        want.safeApprove(_interestToken, type(uint256).max);
        iALPACA.safeApprove(OneInchRouter, type(uint256).max);
        iALPACA.safeApprove(address(pancakeswapRouter), type(uint256).max);
        isBNB = interestToken.token() == wbnb;
    }

    function cloneStrategy(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _interestToken,
        uint256 _pid
    ) external returns (address payable newStrategy) {
        // Copied from https://github.com/optionality/clone-factory/blob/master/contracts/CloneFactory.sol
        bytes20 addressBytes = bytes20(address(this));

        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(clone_code, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(add(clone_code, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            newStrategy := create(0, clone_code, 0x37)
        }

        Strategy(newStrategy).initialize(_vault, _strategist, _rewards, _keeper, _interestToken, _pid);

        emit Cloned(newStrategy);
    }

    function name() external view override returns (string memory) {
        return "StrategyAlpacaLender";
    }

    // returns balance of want
    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function _bankTotalAssets() internal view returns (uint256 _totalAssets) {
        uint256 interest = interestToken.pendingInterest(0);
        BankConfig config = BankConfig(interestToken.config());
        uint256 toReserve = interest.mul(config.getReservePoolBps()).div(10000);

        uint256 vaultDebtVal = interestToken.vaultDebtVal().add(interest);
        uint256 reservePool = interestToken.reservePool().add(toReserve);
        _totalAssets = want.balanceOf(address(interestToken)).add(vaultDebtVal).sub(reservePool);
    }

    function balanceOfRelativeStaked() public view returns (uint256) {
        return balanceOfStake().mul(_bankTotalAssets()).div(interestToken.totalSupply());
    }

    //Returns staked value in masterchef
    function balanceOfStake() public view returns (uint256) {
        return alpacaChef.userInfo(pid, address(this)).amount;
    }

    function pendingReward() public view returns (uint256) {
        return alpacaChef.pendingAlpaca(pid, address(this));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        //Add the vault tokens + staked tokens from 1inch governance contract
        return balanceOfWant().add(balanceOfRelativeStaked());
    }

    function _depositWithBNB(uint256 amount) internal {
        //Deposit to get ibnb
        interestToken.deposit{value: amount}(amount);
        //Finally deposit to masterchef
        alpacaChef.deposit(address(this), pid, interestToken.balanceOf(address(this)));
    }

    function _deposit(uint256 amount) internal {
        //Dont process any extras if its a empty deposit
        if (amount == 0)
            interestToken.deposit{value: 0}(0);
            //If this isnt bnb,direct deposit to chef
        else if (!isBNB) {
            interestToken.deposit{value: 0}(amount);
            alpacaChef.deposit(address(this), pid, interestToken.balanceOf(address(this)));
        } else {
            //First unwrap wbnb to bnb to strat
            iWBNB.withdraw(amount);
            _depositWithBNB(amount);
        }
    }

    function _withdrawInShares(uint256 _shares) internal {
        alpacaChef.withdraw(address(this), pid, _shares);
        interestToken.withdraw(_shares);
    }

    /* Unused func to withdraw exact amount,unused cause it doesnt withdraw exact amount yet
    function _withdraw(uint256 amount) internal {
        //We get the pps and withdraw as much needed
        uint256 pricePerShare = _bankTotalAssets().div(interestToken.totalSupply());
        //Set amount based on price per share
        amount = pricePerShare.div(amount);
        //Withdraw from chef to get interest tokens
        alpacaChef.withdraw(address(this), pid, amount);
        if (!isBNB) {
            interestToken.withdraw(amount);
        } else {
            interestToken.withdraw(amount);
            //Convert bnb back to wbnb
            iWBNB.deposit{value: address(this).balance}();
        }
    }
*/
    function _getRewards(bytes memory _swapData) internal {
        if (pendingReward() > 0) {
            //First claim alpaca rewards
            alpacaChef.deposit(address(this), pid, 0);
            if (want != iALPACA) {
                //swap via pancakeswap to want if we are doing a non 1inch based harvest
                if (_swapData.length == 0)
                    pancakeswapRouter.swapExactTokensForTokens(
                        iALPACA.balanceOf(address(this)),
                        uint256(0),
                        getTokenOutPath(alpaca, address(want)),
                        address(this),
                        now
                    );
                else {
                    (bool success, ) = OneInchRouter.call{value: 0}(_swapData);
                    require(success, "OneInch Swap fails");
                }
            }
        }
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // We might need to return want to the vault
        if (_debtOutstanding > 0) {
            uint256 _amountFreed = 0;
            (_amountFreed, _loss) = liquidatePosition(_debtOutstanding);
            _debtPayment = Math.min(_amountFreed, _debtOutstanding);
        }

        uint256 balanceOfWantBefore = balanceOfWant();
        if (!emergencyExit) _getRewards(new bytes(0));

        _profit = balanceOfWant().sub(balanceOfWantBefore);
    }

    //Harvest code copied with added param to pass call data to execute 1inch swap
    function harvest(bytes calldata swapData) external onlyKeepers {
        uint256 profit = 0;
        uint256 loss = 0;
        uint256 debtOutstanding = vault.debtOutstanding();
        uint256 debtPayment = 0;
        if (emergencyExit) {
            // Free up as much capital as possible
            uint256 totalAssets = estimatedTotalAssets();
            // NOTE: use the larger of total assets or debt outstanding to book losses properly
            (debtPayment, loss) = liquidatePosition(totalAssets > debtOutstanding ? totalAssets : debtOutstanding);
            // NOTE: take up any remainder here as profit
            if (debtPayment > debtOutstanding) {
                profit = debtPayment.sub(debtOutstanding);
                debtPayment = debtOutstanding;
            }
        } else {
            // Free up returns for Vault to pull
            (profit, loss, debtPayment) = prepareReturnWithOneInch(debtOutstanding, swapData);
        }

        // Allow Vault to take up to the "harvested" balance of this contract,
        // which is the amount it has earned since the last time it reported to
        // the Vault.
        debtOutstanding = vault.report(profit, loss, debtPayment);

        // Check if free returns are left, and re-invest them
        adjustPosition(debtOutstanding);

        emit Harvested(profit, loss, debtPayment, debtOutstanding);
    }

    function prepareReturnWithOneInch(uint256 _debtOutstanding, bytes memory _swapData)
        internal
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // We might need to return want to the vault
        if (_debtOutstanding > 0) {
            uint256 _amountFreed = 0;
            (_amountFreed, _loss) = liquidatePosition(_debtOutstanding);
            _debtPayment = Math.min(_amountFreed, _debtOutstanding);
        }

        uint256 balanceOfWantBefore = balanceOfWant();
        if (!emergencyExit) _getRewards(_swapData);

        _profit = balanceOfWant().sub(balanceOfWantBefore);
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _wantAvailable = balanceOfWant();

        if (_debtOutstanding >= _wantAvailable) {
            return;
        }

        uint256 toInvest = _wantAvailable.sub(_debtOutstanding);

        if (toInvest > 0) {
            _deposit(toInvest);
        }
    }

    function getTokenOutPath(address _token_in, address _token_out) internal view returns (address[] memory _path) {
        bool is_wbnb = _token_in == address(wbnb) || _token_out == address(wbnb);
        _path = new address[](is_wbnb ? 2 : 3);
        _path[0] = _token_in;
        if (is_wbnb) {
            _path[1] = _token_out;
        } else {
            _path[1] = address(wbnb);
            _path[2] = _token_out;
        }
    }

    function priceCheck(
        address start,
        address end,
        uint256 _amount
    ) public view returns (uint256) {
        //If we have less than 10 gwei which is considered as dust dont try calculating
        if (_amount < 10 gwei) {
            return 0;
        }
        uint256[] memory amounts = pancakeswapRouter.getAmountsOut(_amount, getTokenOutPath(start, end));
        return amounts[amounts.length - 1];
    }

    function harvestTrigger(uint256 gasCost) public view override returns (bool) {
        StrategyParams memory params = vault.strategies(address(this));

        // Should not trigger if strategy is not activated
        if (params.activation == 0) return false;

        // after enough alpaca rewards has accrued we want the bot to run
        uint256 pendingALPACA = pendingReward();
        uint256 wantGasCost = priceCheck(wbnb, address(want), gasCost);
        uint256 alpacaCost = priceCheck(wbnb, address(alpaca), gasCost);

        //We should harvest if 10% of the alpaca rewards pays the gas costs and 10% + profit on call
        if (alpacaCost.div(10) > gasCost.add(gasCost.div(10))) return true;

        // Should trigger if hadn't been called in a while
        if (block.timestamp.sub(params.lastReport) >= maxReportDelay) return true;

        //check if vault wants lots of money back
        // dont return dust
        uint256 outstanding = vault.debtOutstanding();
        if (outstanding > profitFactor.mul(wantGasCost)) return true;

        // Check for profits and losses
        uint256 total = estimatedTotalAssets();

        uint256 profit = 0;
        if (total > params.totalDebt) profit = total.sub(params.totalDebt); // We've earned a profit!

        uint256 credit = vault.creditAvailable().add(profit);
        return (profitFactor.mul(wantGasCost) < credit);
    }

    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss) {
        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`
        uint256 balanceWant = balanceOfWant();
        uint256 balanceStaked = balanceOfStake();
        if (_amountNeeded > balanceWant) {
            //Unstake full amount
            _withdrawInShares(alpacaChef.userInfo(pid, address(this)).amount);
            //Get how much we need to actually get
            if (isBNB) {
                //Convert the needed balance to wbnb to process withdraw
                iWBNB.deposit{value: _amountNeeded}();
                //Deposit the excess back to farm
                _depositWithBNB(address(this).balance);
            } else {
                //Deposit back excess to farm
                _deposit(balanceOfWant().sub(_amountNeeded));
            }
        }
        // Since we might free more than needed, let's send back the min
        _liquidatedAmount = Math.min(balanceOfWant(), _amountNeeded);
    }

    function prepareMigration(address _newStrategy) internal override {
        _withdrawInShares(alpacaChef.userInfo(pid, address(this)).amount);
        _getRewards(new bytes(0));
        //If this is a wbnb based strat wrap to wbnb to migrate
        if (isBNB) iWBNB.deposit{value: address(this).balance}();
    }

    // Override this to add all tokens/tokenized positions this contract manages
    // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
    function protectedTokens() internal view override returns (address[] memory) {}
}
