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
contract Boron is ERC20Burnable, Operator {
    using SafeMath for uint256;


    constructor(

    ) ERC20("BORON", "BORON") {
        _mint(msg.sender, 45 ether); // mint 45 BORON for team
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