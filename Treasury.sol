// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

// import "@openzeppelin/contracts/math/Math.sol";
// import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
// import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./dependencies/lib/Math.sol";
import "./dependencies/lib/SafeMath.sol";
import "./dependencies/lib/SafeERC20.sol";
import "./dependencies/ReentrancyGuard.sol";

import "./dependencies/lib/Babylonian.sol";
import "./dependencies/Operator.sol";
import "./dependencies/ContractGuard.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IBoardroom.sol";

contract Treasury is ContractGuard {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========= CONSTANT VARIABLES ======== */

    uint256 public constant PERIOD = 6 hours;

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // flags
    bool public initialized = false;

    // epoch
    uint256 public startTime;
    uint256 public epoch = 0;
    uint256 public epochSupplyContractionLeft = 0;

    // exclusions from total supply
    address[] public excludedFromTotalSupply = [
        address(0xB7e1E341b2CBCc7d1EdF4DC6E5e962aE5C621ca5), // MainGenesisRewardPool
        address(0x04b79c851ed1A36549C6151189c79EC0eaBca745) // MainRewardPool
    ];

    // core components
    address public main;
    address public tbond;
    address public share;

    address public boardroom;
    address public mainOracle;

    // price
    uint256 public mainPriceOne;
    uint256 public mainPriceCeiling;

    uint256 public seigniorageSaved;

    uint256[] public supplyTiers;
    uint256[] public maxExpansionTiers;

    uint256 public maxSupplyExpansionPercent;
    uint256 public bondDepletionFloorPercent;
    uint256 public seigniorageExpansionFloorPercent;
    uint256 public maxSupplyContractionPercent;
    uint256 public maxDebtRatioPercent;

    // 28 first epochs (1 week) with 4.5% expansion regardless of MAIN price
    uint256 public bootstrapEpochs;
    uint256 public bootstrapSupplyExpansionPercent;

    /* =================== Added variables =================== */
    uint256 public previousEpochMainPrice;
    uint256 public maxDiscountRate; // when purchasing bond
    uint256 public maxPremiumRate; // when redeeming bond
    uint256 public discountPercent;
    uint256 public premiumThreshold;
    uint256 public premiumPercent;
    uint256 public mintingFactorForPayingDebt; // print extra MAIN during debt phase

    address public daoFund;
    uint256 public daoFundSharedPercent;

    address public devFund;
    uint256 public devFundSharedPercent;

    /* =================== Events =================== */

    event Initialized(address indexed executor, uint256 at);
    event BurnedBonds(address indexed from, uint256 bondAmount);
    event RedeemedBonds(address indexed from, uint256 mainAmount, uint256 bondAmount);
    event BoughtBonds(address indexed from, uint256 mainAmount, uint256 bondAmount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event BoardroomFunded(uint256 timestamp, uint256 seigniorage);
    event DaoFundFunded(uint256 timestamp, uint256 seigniorage);
    event DevFundFunded(uint256 timestamp, uint256 seigniorage);

    /* =================== Modifier =================== */

    modifier onlyOperator() {
        require(operator == msg.sender, "Treasury: caller is not the operator");
        _;
    }

    modifier checkCondition() {
        require(now >= startTime, "Treasury: not started yet");

        _;
    }

    modifier checkEpoch() {
        require(now >= nextEpochPoint(), "Treasury: not opened yet");

        _;

        epoch = epoch.add(1);
        epochSupplyContractionLeft = (getMainPrice() > mainPriceCeiling) ? 0 : getMainCirculatingSupply().mul(maxSupplyContractionPercent).div(10000);
    }

    modifier checkOperator() {
        require(
            IBasisAsset(main).operator() == address(this) &&
                IBasisAsset(tbond).operator() == address(this) &&
                IBasisAsset(share).operator() == address(this) &&
                Operator(boardroom).operator() == address(this),
            "Treasury: need more permission"
        );

        _;
    }

    modifier notInitialized() {
        require(!initialized, "Treasury: already initialized");

        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function isInitialized() public view returns (bool) {
        return initialized;
    }

    // epoch
    function nextEpochPoint() public view returns (uint256) {
        return startTime.add(epoch.mul(PERIOD));
    }

    // oracle
    function getMainPrice() public view returns (uint256 mainPrice) {
        try IOracle(mainOracle).consult(main, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult main price from the oracle");
        }
    }

    function getMainUpdatedPrice() public view returns (uint256 _mainPrice) {
        try IOracle(mainOracle).twap(main, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult main price from the oracle");
        }
    }

    // budget
    function getReserve() public view returns (uint256) {
        return seigniorageSaved;
    }

    function getBurnableMainLeft() public view returns (uint256 _burnableMainLeft) {
        uint256 _mainPrice = getMainPrice();
        if (_mainPrice <= mainPriceOne) {
            uint256 _mainSupply = getMainCirculatingSupply();
            uint256 _bondMaxSupply = _mainSupply.mul(maxDebtRatioPercent).div(10000);
            uint256 _bondSupply = IERC20(tbond).totalSupply();
            if (_bondMaxSupply > _bondSupply) {
                uint256 _maxMintableBond = _bondMaxSupply.sub(_bondSupply);
                uint256 _maxBurnableMain = _maxMintableBond.mul(_mainPrice).div(1e18);
                _burnableMainLeft = Math.min(epochSupplyContractionLeft, _maxBurnableMain);
            }
        }
    }

    function getRedeemableBonds() public view returns (uint256 _redeemableBonds) {
        uint256 _mainPrice = getMainPrice();
        if (_mainPrice > mainPriceCeiling) {
            uint256 _totalMain = IERC20(main).balanceOf(address(this));
            uint256 _rate = getBondPremiumRate();
            if (_rate > 0) {
                _redeemableBonds = _totalMain.mul(1e18).div(_rate);
            }
        }
    }

    function getBondDiscountRate() public view returns (uint256 _rate) {
        uint256 _mainPrice = getMainPrice();
        if (_mainPrice <= mainPriceOne) {
            if (discountPercent == 0) {
                // no discount
                _rate = mainPriceOne;
            } else {
                uint256 _bondAmount = mainPriceOne.mul(1e18).div(_mainPrice); // to burn 1 MAIN
                uint256 _discountAmount = _bondAmount.sub(mainPriceOne).mul(discountPercent).div(10000);
                _rate = mainPriceOne.add(_discountAmount);
                if (maxDiscountRate > 0 && _rate > maxDiscountRate) {
                    _rate = maxDiscountRate;
                }
            }
        }
    }

    function getBondPremiumRate() public view returns (uint256 _rate) {
        uint256 _mainPrice = getMainPrice();
        if (_mainPrice > mainPriceCeiling) {
            uint256 _mainPricePremiumThreshold = mainPriceOne.mul(premiumThreshold).div(100);
            if (_mainPrice >= _mainPricePremiumThreshold) {
                //Price > 1.10
                uint256 _premiumAmount = _mainPrice.sub(mainPriceOne).mul(premiumPercent).div(10000);
                _rate = mainPriceOne.add(_premiumAmount);
                if (maxPremiumRate > 0 && _rate > maxPremiumRate) {
                    _rate = maxPremiumRate;
                }
            } else {
                // no premium bonus
                _rate = mainPriceOne;
            }
        }
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        address _main,
        address _tbond,
        address _share,
        address _mainOracle,
        address _boardroom,
        uint256 _startTime
    ) public notInitialized {
        main = _main;
        tbond = _tbond;
        share = _share;
        mainOracle = _mainOracle;
        boardroom = _boardroom;
        startTime = _startTime;

        mainPriceOne = 10**18; // This is to allow a PEG of 1 MAIN per TOMB
        mainPriceCeiling = mainPriceOne.mul(101).div(100);

        // Dynamic max expansion percent
        supplyTiers = [0 ether, 20_000 ether, 40_000 ether, 60_000 ether, 80_000 ether, 160_000 ether, 500_000 ether, 1_000_000 ether, 2_500_000 ether];
        maxExpansionTiers = [450, 400, 350, 300, 250, 200, 150, 75, 50];

        maxSupplyExpansionPercent = 400; // Upto 4.0% supply for expansion

        bondDepletionFloorPercent = 10000; // 100% of Bond supply for depletion floor
        seigniorageExpansionFloorPercent = 3500; // At least 35% of expansion reserved for boardroom
        maxSupplyContractionPercent = 300; // Upto 3.0% supply for contraction (to burn MAIN and mint TBOND)
        maxDebtRatioPercent = 4000; // Upto 40% supply of TBOND to purchase

        premiumThreshold = 110;
        premiumPercent = 7000;

        // First 18 epochs with 3.75% expansion
        bootstrapEpochs = 18;
        bootstrapSupplyExpansionPercent = 375;

        // set seigniorageSaved to it's balance
        seigniorageSaved = IERC20(main).balanceOf(address(this));

        initialized = true;
        operator = msg.sender;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setBoardroom(address _boardroom) external onlyOperator {
        boardroom = _boardroom;
    }

    function setMainOracle(address _mainOracle) external onlyOperator {
        mainOracle = _mainOracle;
    }

    function setMainPriceCeiling(uint256 _mainPriceCeiling) external onlyOperator {
        require(_mainPriceCeiling >= mainPriceOne && _mainPriceCeiling <= mainPriceOne.mul(120).div(100), "out of range"); // [$1.0, $1.2]
        mainPriceCeiling = _mainPriceCeiling;
    }

    function setMaxSupplyExpansionPercents(uint256 _maxSupplyExpansionPercent) external onlyOperator {
        require(_maxSupplyExpansionPercent >= 10 && _maxSupplyExpansionPercent <= 1000, "_maxSupplyExpansionPercent: out of range"); // [0.1%, 10%]
        maxSupplyExpansionPercent = _maxSupplyExpansionPercent;
    }

    function setSupplyTiersEntry(uint8 _index, uint256 _value) external onlyOperator returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < 9, "Index has to be lower than count of tiers");
        if (_index > 0) {
            require(_value > supplyTiers[_index - 1]);
        }
        if (_index < 8) {
            require(_value < supplyTiers[_index + 1]);
        }
        supplyTiers[_index] = _value;
        return true;
    }

    function setMaxExpansionTiersEntry(uint8 _index, uint256 _value) external onlyOperator returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < 9, "Index has to be lower than count of tiers");
        require(_value >= 10 && _value <= 1000, "_value: out of range"); // [0.1%, 10%]
        maxExpansionTiers[_index] = _value;
        return true;
    }

    function setBondDepletionFloorPercent(uint256 _bondDepletionFloorPercent) external onlyOperator {
        require(_bondDepletionFloorPercent >= 500 && _bondDepletionFloorPercent <= 10000, "out of range"); // [5%, 100%]
        bondDepletionFloorPercent = _bondDepletionFloorPercent;
    }

    function setMaxSupplyContractionPercent(uint256 _maxSupplyContractionPercent) external onlyOperator {
        require(_maxSupplyContractionPercent >= 100 && _maxSupplyContractionPercent <= 1500, "out of range"); // [0.1%, 15%]
        maxSupplyContractionPercent = _maxSupplyContractionPercent;
    }

    function setMaxDebtRatioPercent(uint256 _maxDebtRatioPercent) external onlyOperator {
        require(_maxDebtRatioPercent >= 1000 && _maxDebtRatioPercent <= 10000, "out of range"); // [10%, 100%]
        maxDebtRatioPercent = _maxDebtRatioPercent;
    }

    function setBootstrap(uint256 _bootstrapEpochs, uint256 _bootstrapSupplyExpansionPercent) external onlyOperator {
        require(_bootstrapEpochs <= 120, "_bootstrapEpochs: out of range"); // <= 1 month
        require(_bootstrapSupplyExpansionPercent >= 100 && _bootstrapSupplyExpansionPercent <= 1000, "_bootstrapSupplyExpansionPercent: out of range"); // [1%, 10%]
        bootstrapEpochs = _bootstrapEpochs;
        bootstrapSupplyExpansionPercent = _bootstrapSupplyExpansionPercent;
    }

    function setExtraFunds(
        address _daoFund,
        uint256 _daoFundSharedPercent,
        address _devFund,
        uint256 _devFundSharedPercent
    ) external onlyOperator {
        require(_daoFund != address(0), "zero");
        require(_daoFundSharedPercent <= 2_500, "out of range"); // <= 25%
        require(_devFund != address(0), "zero");
        require(_devFundSharedPercent <= 1_000, "out of range"); // <= 5%
        daoFund = _daoFund;
        daoFundSharedPercent = _daoFundSharedPercent;
        devFund = _devFund;
        devFundSharedPercent = _devFundSharedPercent;
    }

    function setMaxDiscountRate(uint256 _maxDiscountRate) external onlyOperator {
        maxDiscountRate = _maxDiscountRate;
    }

    function setMaxPremiumRate(uint256 _maxPremiumRate) external onlyOperator {
        maxPremiumRate = _maxPremiumRate;
    }

    function setDiscountPercent(uint256 _discountPercent) external onlyOperator {
        require(_discountPercent <= 20000, "_discountPercent is over 200%");
        discountPercent = _discountPercent;
    }

    function setPremiumThreshold(uint256 _premiumThreshold) external onlyOperator {
        require(_premiumThreshold >= mainPriceCeiling, "_premiumThreshold exceeds mainPriceCeiling");
        require(_premiumThreshold <= 150, "_premiumThreshold is higher than 1.5");
        premiumThreshold = _premiumThreshold;
    }

    function setPremiumPercent(uint256 _premiumPercent) external onlyOperator {
        require(_premiumPercent <= 20000, "_premiumPercent is over 200%");
        premiumPercent = _premiumPercent;
    }

    function setMintingFactorForPayingDebt(uint256 _mintingFactorForPayingDebt) external onlyOperator {
        require(_mintingFactorForPayingDebt >= 10000 && _mintingFactorForPayingDebt <= 20000, "_mintingFactorForPayingDebt: out of range"); // [100%, 200%]
        mintingFactorForPayingDebt = _mintingFactorForPayingDebt;
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updateMainPrice() internal {
        try IOracle(mainOracle).update() {} catch {}
    }

    function getMainCirculatingSupply() public view returns (uint256) {
        IERC20 mainErc20 = IERC20(main);
        uint256 totalSupply = mainErc20.totalSupply();
        uint256 balanceExcluded = 0;
        for (uint8 entryId = 0; entryId < excludedFromTotalSupply.length; ++entryId) {
            balanceExcluded = balanceExcluded.add(mainErc20.balanceOf(excludedFromTotalSupply[entryId]));
        }
        return totalSupply.sub(balanceExcluded);
    }

    function buyBonds(uint256 _mainAmount, uint256 targetPrice) external onlyOneBlock checkCondition checkOperator {
        require(_mainAmount > 0, "Treasury: cannot purchase bonds with zero amount");

        uint256 mainPrice = getMainPrice();
        require(mainPrice == targetPrice, "Treasury: MAIN price moved");
        require(
            mainPrice < mainPriceOne, // price < $1
            "Treasury: mainPrice not eligible for bond purchase"
        );

        require(_mainAmount <= epochSupplyContractionLeft, "Treasury: not enough bond left to purchase");

        uint256 _rate = getBondDiscountRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _bondAmount = _mainAmount.mul(_rate).div(1e18);
        uint256 mainSupply = getMainCirculatingSupply();
        uint256 newBondSupply = IERC20(tbond).totalSupply().add(_bondAmount);
        require(newBondSupply <= mainSupply.mul(maxDebtRatioPercent).div(10000), "over max debt ratio");

        IBasisAsset(main).burnFrom(msg.sender, _mainAmount);
        IBasisAsset(tbond).mint(msg.sender, _bondAmount);

        epochSupplyContractionLeft = epochSupplyContractionLeft.sub(_mainAmount);
        _updateMainPrice();

        emit BoughtBonds(msg.sender, _mainAmount, _bondAmount);
    }

    function redeemBonds(uint256 _bondAmount, uint256 targetPrice) external onlyOneBlock checkCondition checkOperator {
        require(_bondAmount > 0, "Treasury: cannot redeem bonds with zero amount");

        uint256 mainPrice = getMainPrice();
        require(mainPrice == targetPrice, "Treasury: MAIN price moved");
        require(
            mainPrice > mainPriceCeiling, // price > $1.01
            "Treasury: mainPrice not eligible for bond purchase"
        );

        uint256 _rate = getBondPremiumRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _mainAmount = _bondAmount.mul(_rate).div(1e18);
        require(IERC20(main).balanceOf(address(this)) >= _mainAmount, "Treasury: treasury has no more budget");

        seigniorageSaved = seigniorageSaved.sub(Math.min(seigniorageSaved, _mainAmount));

        IBasisAsset(tbond).burnFrom(msg.sender, _bondAmount);
        IERC20(main).safeTransfer(msg.sender, _mainAmount);

        _updateMainPrice();

        emit RedeemedBonds(msg.sender, _mainAmount, _bondAmount);
    }

    function _sendToBoardroom(uint256 _amount) internal {

        //Mint new main.
        IBasisAsset(main).mint(address(this), _amount);

        uint256 _daoFundSharedAmount = 0;
        if (daoFundSharedPercent > 0) {
            _daoFundSharedAmount = _amount.mul(daoFundSharedPercent).div(10000);
            IERC20(main).transfer(daoFund, _daoFundSharedAmount);
            emit DaoFundFunded(now, _daoFundSharedAmount);
        }

        uint256 _devFundSharedAmount = 0;
        if (devFundSharedPercent > 0) {
            _devFundSharedAmount = _amount.mul(devFundSharedPercent).div(10000);
            IERC20(main).transfer(devFund, _devFundSharedAmount);
            emit DevFundFunded(now, _devFundSharedAmount);
        }

        _amount = _amount.sub(_daoFundSharedAmount).sub(_devFundSharedAmount);

        IERC20(main).safeApprove(boardroom, 0);
        IERC20(main).safeApprove(boardroom, _amount);

        IBoardroom(boardroom).allocateSeigniorage(_amount);
        emit BoardroomFunded(now, _amount);
    }

    function _calculateMaxSupplyExpansionPercent(uint256 _mainSupply) internal returns (uint256) {
        for (uint8 tierId = 8; tierId >= 0; --tierId) {
            if (_mainSupply >= supplyTiers[tierId]) {
                maxSupplyExpansionPercent = maxExpansionTiers[tierId];
                break;
            }
        }
        return maxSupplyExpansionPercent;
    }

    function allocateSeigniorage() external onlyOneBlock checkCondition checkEpoch checkOperator {

        _updateMainPrice();

        previousEpochMainPrice = getMainPrice();

        uint256 mainSupply = getMainCirculatingSupply().sub(seigniorageSaved);

        if (epoch < bootstrapEpochs) {
            _sendToBoardroom(mainSupply.mul(bootstrapSupplyExpansionPercent).div(10000));
        } else {
            //allow expansion.
            if (previousEpochMainPrice > mainPriceCeiling) {

                //Get the total amount of bonds in existence.
                uint256 bondSupply = IERC20(tbond).totalSupply();

                uint256 _percentage = previousEpochMainPrice.sub(mainPriceOne);

                uint256 _savedForBond;
                uint256 _savedForBoardroom;

                //Maximum supply expansion. 
                uint256 _mse = _calculateMaxSupplyExpansionPercent(mainSupply).mul(1e14);

                if (_percentage > _mse) {
                    _percentage = _mse;
                }

                if (seigniorageSaved >= bondSupply.mul(bondDepletionFloorPercent).div(10000)) {
                    _savedForBoardroom = mainSupply.mul(_percentage).div(1e18);
                } else {
                    uint256 _seigniorage = mainSupply.mul(_percentage).div(1e18);

                    _savedForBoardroom = _seigniorage.mul(seigniorageExpansionFloorPercent).div(10000);

                    _savedForBond = _seigniorage.sub(_savedForBoardroom);
                    if (mintingFactorForPayingDebt > 0) {
                        _savedForBond = _savedForBond.mul(mintingFactorForPayingDebt).div(10000);
                    }
                }

                //Send to boardroom.
                if (_savedForBoardroom > 0) {
                    _sendToBoardroom(_savedForBoardroom);
                }

                //Add the bond amount to the treasury. - i.e. this contract.
                if (_savedForBond > 0) {
                    seigniorageSaved = seigniorageSaved.add(_savedForBond);
                    IBasisAsset(main).mint(address(this), _savedForBond);
                    emit TreasuryFunded(now, _savedForBond);
                }
            }
        }
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        // do not allow to drain core tokens
        require(address(_token) != address(main), "main");
        require(address(_token) != address(tbond), "bond");
        require(address(_token) != address(share), "share");
        _token.safeTransfer(_to, _amount);
    }

    function boardroomSetOperator(address _operator) external onlyOperator {
        IBoardroom(boardroom).setOperator(_operator);
    }

    function boardroomSetLockUp(uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs) external onlyOperator {
        IBoardroom(boardroom).setLockUp(_withdrawLockupEpochs, _rewardLockupEpochs);
    }

    function boardroomAllocateSeigniorage(uint256 amount) external onlyOperator {
        IBoardroom(boardroom).allocateSeigniorage(amount);
    }

    function boardroomGovernanceRecoverUnsupported(
        address _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        IBoardroom(boardroom).governanceRecoverUnsupported(_token, _amount, _to);
    }

    function setExcludedFromTotalSupply(address[] calldata _excludedFromTotalSupply) external onlyOperator {
        excludedFromTotalSupply = _excludedFromTotalSupply;
    }
}