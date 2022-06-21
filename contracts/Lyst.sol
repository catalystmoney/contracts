// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import "./owner/Operator.sol";

/*
_________         __           ___________.__                                   
\_   ___ \_____ _/  |______    \_   _____/|__| ____ _____    ____   ____  ____  
/    \  \/\__  \\   __\__  \    |    __)  |  |/    \\__  \  /    \_/ ___\/ __ \ 
\     \____/ __ \|  |  / __ \_  |     \   |  |   |  \/ __ \|   |  \  \__\  ___/ 
 \______  (____  /__| (____  /  \___  /   |__|___|  (____  /___|  /\___  >___  >
        \/     \/          \/       \/            \/     \/     \/     \/    \/
*/
contract Lyst is ERC20Burnable, Operator {
    using SafeMath for uint256;

    // TOTAL MAX SUPPLY = 50,000 Lyst
    uint256 public constant FARMING_POOL_REWARD_ALLOCATION = 50000 ether;


    bool public rewardPoolDistributed = false;

    constructor(

    ) ERC20("LYST", "LYST") {
        _mint(msg.sender, 10 ether); // mint 10 Lyst for initial pools deployment
    }
    /**
     * @notice distribute to reward pool (only once)
     */
    function distributeReward(address _farmingIncentiveFund) external onlyOperator {
        require(!rewardPoolDistributed, "only can distribute once");
        require(_farmingIncentiveFund != address(0), "!_farmingIncentiveFund");
        rewardPoolDistributed = true;
        _mint(_farmingIncentiveFund, FARMING_POOL_REWARD_ALLOCATION);
    }

    function burn(uint256 amount) public override {
        super.burn(amount);
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        _token.transfer(_to, _amount);
    }
}