// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./libraries/Silicon.sol";
import "./owner/Operator.sol";
import "./utils/ContractGuard.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IReactor.sol";
import "./owner/Operator.sol";

/*
_________         __           ___________.__                                   
\_   ___ \_____ _/  |______    \_   _____/|__| ____ _____    ____   ____  ____  
/    \  \/\__  \\   __\__  \    |    __)  |  |/    \\__  \  /    \_/ ___\/ __ \ 
\     \____/ __ \|  |  / __ \_  |     \   |  |   |  \/ __ \|   |  \  \__\  ___/ 
 \______  (____  /__| (____  /  \___  /   |__|___|  (____  /___|  /\___  >___  >
        \/     \/          \/       \/            \/     \/     \/     \/    \/
*/
contract Treasury is ContractGuard, Operator {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========= CONSTANT VARIABLES ======== */

    uint256 public constant PERIOD = 6 hours;

    /* ========== STATE VARIABLES ========== */

    // flags
    bool public initialized = false;

    // epoch
    uint256 public startTime;
    uint256 public epoch = 0;
    uint256 public epochSupplyContractionLeft = 0;

    //=================================================================// exclusions from total supply
    address[] public excludedFromTotalSupply = [
        address(0x9Ec66B9409d4cD8D4a4C90950Ff0fd26bB39ad84) // CataGenesisPool
    ];

    // core components
    address public cata;
    address public cbond;
    address public lyst;

    address public reactor;
    address public cataOracle;

    // price
    uint256 public cataPriceOne;
    uint256 public cataPriceCeiling;

    uint256 public seigniorageSaved;

    uint256[] public supplyTiers;
    uint256[] public maxExpansionTiers;

    uint256 public maxSupplyExpansionPercent;
    uint256 public bondDepletionFloorPercent;
    uint256 public seigniorageExpansionFloorPercent;
    uint256 public maxSupplyContractionPercent;
    uint256 public maxDebtRatioPercent;

    // 14 first epochs (0.5 week) with 4.5% expansion regardless of Cata price
    uint256 public bootstrapEpochs;
    uint256 public bootstrapSupplyExpansionPercent;

    /* =================== Added variables =================== */
    uint256 public previousEpochCataPrice;
    uint256 public maxDiscountRate; // when purchasing bond
    uint256 public maxPremiumRate;  // when redeeming bond
    uint256 public discountPercent;
    uint256 public premiumThreshold;
    uint256 public premiumPercent;
    uint256 public mintingFactorForPayingDebt; // print extra Cata during debt phase

    address public daoFund;
    uint256 public daoFundSharedPercent;

    //=================================================//

    address public devFund;
    uint256 public devFundSharedPercent;

    /* =================== Events =================== */

    event Initialized(address indexed executor, uint256 at);
    event BurnedBonds(address indexed from, uint256 bondAmount);
    event RedeemedBonds(address indexed from, uint256 cataAmount, uint256 bondAmount);
    event BoughtBonds(address indexed from, uint256 cataAmount, uint256 bondAmount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event ReactorFunded(uint256 timestamp, uint256 seigniorage);
    event DaoFundFunded(uint256 timestamp, uint256 seigniorage);
    event DevFundFunded(uint256 timestamp, uint256 seigniorage);
    event TeamFundFunded(uint256 timestamp, uint256 seigniorage);

    /* =================== Modifier =================== */

    modifier checkCondition {
        require(block.timestamp >= startTime, "Treasury: not started yet");

        _;
    }

    modifier checkEpoch {
        require(block.timestamp >= nextEpochPoint(), "Treasury: not opened yet");

        _;

        epoch = epoch.add(1);
        epochSupplyContractionLeft = (getCataPrice() > cataPriceCeiling) ? 0 : getCataCirculatingSupply().mul(maxSupplyContractionPercent).div(10000);
    }

    modifier checkOperator {
        require(
                IBasisAsset(cata).operator() == address(this) &&
                IBasisAsset(cbond).operator() == address(this) &&
                IBasisAsset(lyst).operator() == address(this) &&
                Operator(reactor).operator() == address(this),
            "Treasury: need more permission"
        );

        _;
    }

    modifier notInitialized {
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
    function getCataPrice() public view returns (uint256 cataPrice) {
        try IOracle(cataOracle).consult(cata, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult Cata price from the oracle");
        }
    }

    function getCataUpdatedPrice() public view returns (uint256 _cataPrice) {
        try IOracle(cataOracle).twap(cata, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult Cata price from the oracle");
        }
    }

    // budget
    function getReserve() public view returns (uint256) {
        return seigniorageSaved;
    }

    function getBurnableCataLeft() public view returns (uint256 _burnableCataLeft) {
        uint256 _cataPrice = getCataPrice();
        if (_cataPrice <= cataPriceOne) {
            uint256 _cataSupply = getCataCirculatingSupply();
            uint256 _bondMaxSupply = _cataSupply.mul(maxDebtRatioPercent).div(10000);
            uint256 _bondSupply = IERC20(cbond).totalSupply();
            if (_bondMaxSupply > _bondSupply) {
                uint256 _maxMintableBond = _bondMaxSupply.sub(_bondSupply);
                uint256 _maxBurnableCata = _maxMintableBond.mul(_cataPrice).div(1e18);
                _burnableCataLeft = Math.min(epochSupplyContractionLeft, _maxBurnableCata);
            }
        }
    }

    function getRedeemableBonds() public view returns (uint256 _redeemableBonds) {
        uint256 _CataPrice = getCataPrice();
        if (_CataPrice > cataPriceCeiling) {
            uint256 _totalCata = IERC20(cata).balanceOf(address(this));
            uint256 _rate = getBondPremiumRate();
            if (_rate > 0) {
                _redeemableBonds = _totalCata.mul(1e18).div(_rate);
            }
        }
    }

    function getBondDiscountRate() public view returns (uint256 _rate) {
        uint256 _cataPrice = getCataPrice();
        if (_cataPrice <= cataPriceOne) {
            if (discountPercent == 0) {
                // no discount
                _rate = cataPriceOne;
            } else {
                uint256 _bondAmount = cataPriceOne.mul(1e18).div(_cataPrice); // to burn 1 Cata
                uint256 _discountAmount = _bondAmount.sub(cataPriceOne).mul(discountPercent).div(10000);
                _rate = cataPriceOne.add(_discountAmount);
                if (maxDiscountRate > 0 && _rate > maxDiscountRate) {
                    _rate = maxDiscountRate;
                }
            }
        }
    }

    function getBondPremiumRate() public view returns (uint256 _rate) {
        uint256 _cataPrice = getCataPrice();
        if (_cataPrice > cataPriceCeiling) {
            uint256 _cataPricePremiumThreshold = cataPriceOne.mul(premiumThreshold).div(100);
            if (_cataPrice >= _cataPricePremiumThreshold) {
                //Price > 1.10
                uint256 _premiumAmount = _cataPrice.sub(cataPriceOne).mul(premiumPercent).div(10000);
                _rate = cataPriceOne.add(_premiumAmount);
                if (maxPremiumRate > 0 && _rate > maxPremiumRate) {
                    _rate = maxPremiumRate;
                }
            } else {
                // no premium bonus
                _rate = cataPriceOne;
            }
        }
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        address _cata,
        address _cbond,
        address _lyst,
        address _cataOracle,
        address _reactor,
        uint256 _startTime
    ) public notInitialized onlyOperator {
        cata = _cata;
        cbond = _cbond;
        lyst = _lyst;
        cataOracle = _cataOracle;
        reactor = _reactor;
        startTime = _startTime;

        cataPriceOne = 10 ** 18;
        cataPriceCeiling = cataPriceOne.mul(101).div(100);

        // Dynamic max expansion percent
        supplyTiers = [0 ether, 500000 ether, 1000000 ether, 1500000 ether, 2000000 ether, 5000000 ether, 10000000 ether, 20000000 ether, 50000000 ether];
        maxExpansionTiers = [450, 400, 350, 300, 250, 200, 150, 125, 100];

        maxSupplyExpansionPercent = 450; // Upto 6% supply for expansion

        bondDepletionFloorPercent = 10000; // 100% of Bond supply for depletion floor
        seigniorageExpansionFloorPercent = 3500; // At least 35% of expansion reserved for reactor
        maxSupplyContractionPercent = 300; // Upto 3.0% supply for contraction (to burn cata and mint cBond)
        maxDebtRatioPercent = 4000; // Upto 35% supply of cBond to purchase

        premiumThreshold = 110;
        premiumPercent = 7000;

        // First 14 epochs with 4.5% expansion
        bootstrapEpochs = 14;
        bootstrapSupplyExpansionPercent = 450;

        // set seigniorageSaved to it's balance
        seigniorageSaved = IERC20(cata).balanceOf(address(this));

        initialized = true;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        transferOperator(_operator);
    }

    function renounceOperator() external onlyOperator {
        _renounceOperator();
    }

    function setReactor(address _reactor) external onlyOperator {
        reactor = _reactor;
    }

    function setCataOracle(address _cataOracle) external onlyOperator {
        cataOracle = _cataOracle;
    }

    function setCataPriceCeiling(uint256 _cataPriceCeiling) external onlyOperator {
        require(_cataPriceCeiling >= cataPriceOne && _cataPriceCeiling <= cataPriceOne.mul(120).div(100), "out of range"); // [$1.0, $1.2]
        cataPriceCeiling = _cataPriceCeiling;
    }

    function setMaxSupplyExpansionPercents(uint256 _maxSupplyExpansionPercent) external onlyOperator {
        require(_maxSupplyExpansionPercent >= 10 && _maxSupplyExpansionPercent <= 1000, "_maxSupplyExpansionPercent: out of range"); // [0.1%, 10%]
        maxSupplyExpansionPercent = _maxSupplyExpansionPercent;
    }
    // =================== ALTER THE NUMBERS IN LOGIC!!!! =================== //
    function setSupplyTiersEntry(uint8 _index, uint256 _value) external onlyOperator returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < 7, "Index has to be lower than count of tiers");
        if (_index > 0) {
            require(_value > supplyTiers[_index - 1]);
        }
        if (_index < 6) {
            require(_value < supplyTiers[_index + 1]);
        }
        supplyTiers[_index] = _value;
        return true;
    }

    function setMaxExpansionTiersEntry(uint8 _index, uint256 _value) external onlyOperator returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < 7, "Index has to be lower than count of tiers");
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
    //======================================================================
    function setExtraFunds(
        address _daoFund,
        uint256 _daoFundSharedPercent,
        address _devFund,
        uint256 _devFundSharedPercent
    ) external onlyOperator {
        require(_daoFund != address(0), "zero");
        require(_daoFundSharedPercent <= 2500, "out of range");
        require(_devFund != address(0), "zero");
        require(_devFundSharedPercent <= 1000, "out of range");


        daoFund = _daoFund;
        daoFundSharedPercent = _daoFundSharedPercent;
        devFund = _devFund;
        devFundSharedPercent = _devFundSharedPercent;
    }

    function setMaxDiscountRate(uint256 _maxDiscountRate) external onlyOperator {
        require(_maxDiscountRate <= 20000, "_maxDiscountRate is over 200%");
        maxDiscountRate = _maxDiscountRate;
    }

    function setMaxPremiumRate(uint256 _maxPremiumRate) external onlyOperator {
        require(_maxPremiumRate <= 20000, "_maxPremiumRate is over 200%");
        maxPremiumRate = _maxPremiumRate;
    }

    function setDiscountPercent(uint256 _discountPercent) external onlyOperator {
        require(_discountPercent <= 20000, "_discountPercent is over 200%");
        discountPercent = _discountPercent;
    }

    function setPremiumThreshold(uint256 _premiumThreshold) external onlyOperator {
        require(_premiumThreshold >= cataPriceCeiling, "_premiumThreshold exceeds cataPriceCeiling");
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

    function _updateCataPrice() internal {
        try IOracle(cataOracle).update() {} catch {}
    }

    function getCataCirculatingSupply() public view returns (uint256) {
        IERC20 cataErc20 = IERC20(cata);
        uint256 totalSupply = cataErc20.totalSupply();
        uint256 balanceExcluded = 0;
        for (uint8 entryId = 0; entryId < excludedFromTotalSupply.length; ++entryId) {
            balanceExcluded = balanceExcluded.add(cataErc20.balanceOf(excludedFromTotalSupply[entryId]));
        }
        return totalSupply.sub(balanceExcluded);
    }

    function buyBonds(uint256 _cataAmount, uint256 targetPrice) external onlyOneBlock checkCondition checkOperator {
        require(_cataAmount > 0, "Treasury: cannot purchase bonds with zero amount");

        uint256 cataPrice = getCataPrice();
        require(cataPrice == targetPrice, "Treasury: Cata price moved");
        require(
            cataPrice < cataPriceOne, // price < $1
            "Treasury: Cata Price not eligible for bond purchase"
        );

        require(_cataAmount <= epochSupplyContractionLeft, "Treasury: not enough bond left to purchase");

        uint256 _rate = getBondDiscountRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _bondAmount = _cataAmount.mul(_rate).div(1e18);
        uint256 cataSupply = getCataCirculatingSupply();
        uint256 newBondSupply = IERC20(cbond).totalSupply().add(_bondAmount);
        require(newBondSupply <= cataSupply.mul(maxDebtRatioPercent).div(10000), "over max debt ratio");

        IBasisAsset(cata).burnFrom(msg.sender, _cataAmount);
        IBasisAsset(cbond).mint(msg.sender, _bondAmount);

        epochSupplyContractionLeft = epochSupplyContractionLeft.sub(_cataAmount);
        _updateCataPrice();

        emit BoughtBonds(msg.sender, _cataAmount, _bondAmount);
    }

    function redeemBonds(uint256 _bondAmount, uint256 targetPrice) external onlyOneBlock checkCondition checkOperator {
        require(_bondAmount > 0, "Treasury: cannot redeem bonds with zero amount");

        uint256 cataPrice = getCataPrice();
        require(cataPrice == targetPrice, "Treasury: Cata price moved");
        require(
            cataPrice > cataPriceCeiling, // price > $1.01
            "Treasury: Cata Price not eligible for bond purchase"
        );

        uint256 _rate = getBondPremiumRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _cataAmount = _bondAmount.mul(_rate).div(1e18);
        require(IERC20(cata).balanceOf(address(this)) >= _cataAmount, "Treasury: treasury has no more budget");

        seigniorageSaved = seigniorageSaved.sub(Math.min(seigniorageSaved, _cataAmount));

        IBasisAsset(cbond).burnFrom(msg.sender, _bondAmount);
        IERC20(cata).safeTransfer(msg.sender, _cataAmount);

        _updateCataPrice();

        emit RedeemedBonds(msg.sender, _cataAmount, _bondAmount);
    }

    function _sendToReactor(uint256 _amount) internal {
        IBasisAsset(cata).mint(address(this), _amount);

        uint256 _daoFundSharedAmount = 0;
        if (daoFundSharedPercent > 0) {
            _daoFundSharedAmount = _amount.mul(daoFundSharedPercent).div(10000);
            IERC20(cata).transfer(daoFund, _daoFundSharedAmount);
            emit DaoFundFunded(block.timestamp, _daoFundSharedAmount);
        }

        uint256 _devFundSharedAmount = 0;
        if (devFundSharedPercent > 0) {
            _devFundSharedAmount = _amount.mul(devFundSharedPercent).div(10000);
            IERC20(cata).transfer(devFund, _devFundSharedAmount);
            emit DevFundFunded(block.timestamp, _devFundSharedAmount);
        }


        _amount = _amount.sub(_daoFundSharedAmount).sub(_devFundSharedAmount);

        IERC20(cata).safeApprove(reactor, 0);
        IERC20(cata).safeApprove(reactor, _amount);
        IReactor(reactor).allocateSeigniorage(_amount);
        emit ReactorFunded(block.timestamp, _amount);
    }

    function _calculateMaxSupplyExpansionPercent(uint256 _cataSupply) internal returns (uint256) {
        for (uint8 tierId = 6; tierId >= 0; --tierId) {
            if (_cataSupply >= supplyTiers[tierId]) {
                maxSupplyExpansionPercent = maxExpansionTiers[tierId];
                break;
            }
        }
        return maxSupplyExpansionPercent;
    }

    function allocateSeigniorage() external onlyOneBlock checkCondition checkEpoch checkOperator {
        _updateCataPrice();
        previousEpochCataPrice = getCataPrice();
        uint256 cataSupply = getCataCirculatingSupply().sub(seigniorageSaved);
        if (epoch < bootstrapEpochs) {
            // 14 first epochs with 6% expansion
            _sendToReactor(cataSupply.mul(bootstrapSupplyExpansionPercent).div(10000));
        } else {
            if (previousEpochCataPrice > cataPriceCeiling) {
                // Expansion ($Cata Price > 1 $EMP): there is some seigniorage to be allocated
                uint256 bondSupply = IERC20(cbond).totalSupply();
                uint256 _percentage = previousEpochCataPrice.sub(cataPriceOne);
                uint256 _savedForBond;
                uint256 _savedForReactor;
                uint256 _mse = _calculateMaxSupplyExpansionPercent(cataSupply).mul(1e14);
                if (_percentage > _mse) {
                    _percentage = _mse;
                }
                if (seigniorageSaved >= bondSupply.mul(bondDepletionFloorPercent).div(10000)) {
                    // saved enough to pay debt, mint as usual rate
                    _savedForReactor = cataSupply.mul(_percentage).div(1e18);
                } else {
                    // have not saved enough to pay debt, mint more
                    uint256 _seigniorage = cataSupply.mul(_percentage).div(1e18);
                    _savedForReactor = _seigniorage.mul(seigniorageExpansionFloorPercent).div(10000);
                    _savedForBond = _seigniorage.sub(_savedForReactor);
                    if (mintingFactorForPayingDebt > 0) {
                        _savedForBond = _savedForBond.mul(mintingFactorForPayingDebt).div(10000);
                    }
                }
                if (_savedForReactor > 0) {
                    _sendToReactor(_savedForReactor);
                }
                if (_savedForBond > 0) {
                    seigniorageSaved = seigniorageSaved.add(_savedForBond);
                    IBasisAsset(cata).mint(address(this), _savedForBond);
                    emit TreasuryFunded(block.timestamp, _savedForBond);
                }
            }
        }
    }
    //===================================================================================================================================

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        // do not allow to drain core tokens
        require(address(_token) != address(cata), "cata");
        require(address(_token) != address(cbond), "cbond");
        require(address(_token) != address(lyst), "lyst");
        _token.safeTransfer(_to, _amount);
    }

    function reactorSetOperator(address _operator) external onlyOperator {
        IReactor(reactor).setOperator(_operator);
    }

    function reactorSetLockUp(uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs) external onlyOperator {
        IReactor(reactor).setLockUp(_withdrawLockupEpochs, _rewardLockupEpochs);
    }

    function reactorAllocateSeigniorage(uint256 amount) external onlyOperator {
        IReactor(reactor).allocateSeigniorage(amount);
    }

    function reactorGovernanceRecoverUnsupported(
        address _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        IReactor(reactor).governanceRecoverUnsupported(_token, _amount, _to);
    }
}