// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "./libraries/SafeMath8.sol";
import "./owner/Operator.sol";
import "./interfaces/IOracle.sol";

/*
_________         __           ___________.__                                   
\_   ___ \_____ _/  |______    \_   _____/|__| ____ _____    ____   ____  ____  
/    \  \/\__  \\   __\__  \    |    __)  |  |/    \\__  \  /    \_/ ___\/ __ \ 
\     \____/ __ \|  |  / __ \_  |     \   |  |   |  \/ __ \|   |  \  \__\  ___/ 
 \______  (____  /__| (____  /  \___  /   |__|___|  (____  /___|  /\___  >___  >
        \/     \/          \/       \/            \/     \/     \/     \/    \/
*/
contract Cata is ERC20Burnable, Operator {
    using SafeMath8 for uint8;
    using SafeMath for uint256;

    // Initial distribution for the first 48h genesis pools
    // total of Cata we pay to users during genesis
    uint256 public constant INITIAL_GENESIS_POOL_DISTRIBUTION = 27500 ether;

    // DAO FUND INITIAL ALLOCATION IS 1000 CATA
    uint256 public constant INITIAL_DAOFUND_DISTRIBUTION = 1000 ether;


    // Have the rewards been distributed to the pools
    bool public rewardPoolDistributed = false;


    // Address of the Oracle
    address public cataOracle;

    /**
     * @notice Constructs the CATA ERC-20 contract.
     */
    constructor() ERC20("CATA", "CATA") {
        // Mints 2500 CATA to contract creator for initial pool setup

        _mint(msg.sender, 2500 ether);

    }

    function _getCataPrice() internal view returns (uint256 _cataPrice) {
        try IOracle(cataOracle).consult(address(this), 1e18) returns (uint144 _price) {
            return uint256(_price);
        } catch {
            revert("Cata: failed to fetch CATA price from Oracle");
        }
    }

    function setCataOracle(address _CataOracle) public onlyOperator {
        require(_CataOracle != address(0), "oracle address cannot be 0 address");
        cataOracle = _CataOracle;
    }

    /**
     * @notice Operator mints CATA to a recipient
     * @param recipient_ The address of recipient
     * @param amount_ The amount of CATA to mint to
     * @return whether the process has been done
     */
    function mint(address recipient_, uint256 amount_) public onlyOperator returns (bool) {
        uint256 balanceBefore = balanceOf(recipient_);
        _mint(recipient_, amount_);
        uint256 balanceAfter = balanceOf(recipient_);

        return balanceAfter > balanceBefore;
    }

    function burn(uint256 amount) public override {
        super.burn(amount);
    }

    function burnFrom(address account, uint256 amount) public override onlyOperator {
        super.burnFrom(account, amount);
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), allowance(sender, _msgSender()).sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }

    /**
     * @notice distribute to reward pool (only once)
     */
    function distributeReward(
        address _genesisPool,
        address _daoFund

    ) external onlyOperator {
        require(!rewardPoolDistributed, "only can distribute once");
        require(_genesisPool != address(0), "!_genesisPool");
        require(_daoFund != address(0), "!_treasury");

        rewardPoolDistributed = true;
        _mint(_genesisPool, INITIAL_GENESIS_POOL_DISTRIBUTION);
        _mint(_daoFund, INITIAL_DAOFUND_DISTRIBUTION);

    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        _token.transfer(_to, _amount);
    }
}