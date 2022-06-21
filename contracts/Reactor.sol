// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "./utils/ContractGuard.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/ITreasury.sol";
import "./owner/Operator.sol";

contract LystWrapper {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 public lyst;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function stake(uint256 amount) public virtual {
        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        lyst.safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 amount) public virtual {
        uint256 andrasShare = _balances[msg.sender];
        require(andrasShare >= amount, "Reactor: withdraw request greater than staked amount");
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = andrasShare.sub(amount);
        lyst.safeTransfer(msg.sender, amount);
    }
}

/*
_________         __           ___________.__                                   
\_   ___ \_____ _/  |______    \_   _____/|__| ____ _____    ____   ____  ____  
/    \  \/\__  \\   __\__  \    |    __)  |  |/    \\__  \  /    \_/ ___\/ __ \ 
\     \____/ __ \|  |  / __ \_  |     \   |  |   |  \/ __ \|   |  \  \__\  ___/ 
 \______  (____  /__| (____  /  \___  /   |__|___|  (____  /___|  /\___  >___  >
        \/     \/          \/       \/            \/     \/     \/     \/    \/
*/
contract Reactor is LystWrapper, ContractGuard, Operator {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== DATA STRUCTURES ========== */

    struct Halide {
        uint256 lastSnapshotIndex;
        uint256 rewardEarned;
        uint256 epochTimerStart;
    }

    struct ReactorSnapshot {
        uint256 time;
        uint256 rewardReceived;
        uint256 rewardPerShare;
    }

    /* ========== STATE VARIABLES ========== */

    // flags
    bool public initialized = false;

    IERC20 public cata;
    ITreasury public treasury;

    mapping(address => Halide) public sulfide;
    ReactorSnapshot[] public reactorHistory;

    uint256 public withdrawLockupEpochs;
    uint256 public rewardLockupEpochs;

    /* ========== EVENTS ========== */

    event Initialized(address indexed executor, uint256 at);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(address indexed user, uint256 reward);

    /* ========== Modifiers =============== */

    modifier oxideExists {
        require(balanceOf(msg.sender) > 0, "Reactor: The oxide does not exist");
        _;
    }

    modifier updateReward(address oxide) {
        if (oxide != address(0)) {
            Halide memory halide = sulfide[oxide];
            halide.rewardEarned = earned(oxide);
            halide.lastSnapshotIndex = latestSnapshotIndex();
            sulfide[oxide] = halide;
        }
        _;
    }

    modifier notInitialized {
        require(!initialized, "Reactor: already Enabled");
        _;
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        IERC20 _cata,
        IERC20 _lyst,
        ITreasury _treasury
    ) public notInitialized onlyOperator {
        cata = _cata;
        lyst = _lyst;
        treasury = _treasury;

        ReactorSnapshot memory genesisSnapshot = ReactorSnapshot({time : block.number, rewardReceived : 0, rewardPerShare : 0});
        reactorHistory.push(genesisSnapshot);

        withdrawLockupEpochs = 4; // Lock for 4 epochs (24h) before release withdraw
        rewardLockupEpochs = 2; // Lock for 2 epochs (12h) before release claimReward

        initialized = true;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        transferOperator(_operator);
    }

    function renounceOperator() external onlyOperator {
        _renounceOperator();
    }

    function setLockUp(uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs) external onlyOperator {
        require(_withdrawLockupEpochs >= _rewardLockupEpochs && _withdrawLockupEpochs <= 56, "_withdrawLockupEpochs: out of range"); // <= 2 week
        require(_withdrawLockupEpochs > 0 && _rewardLockupEpochs > 0);
        withdrawLockupEpochs = _withdrawLockupEpochs;
        rewardLockupEpochs = _rewardLockupEpochs;
    }

    /* ========== VIEW FUNCTIONS ========== */

    // =========== Snapshot getters =========== //

    function latestSnapshotIndex() public view returns (uint256) {
        return reactorHistory.length.sub(1);
    }

    function getLatestSnapshot() internal view returns (ReactorSnapshot memory) {
        return reactorHistory[latestSnapshotIndex()];
    }

    function getLastSnapshotIndexOf(address andras) public view returns (uint256) {
        return sulfide[andras].lastSnapshotIndex;
    }

    function getLastSnapshotOf(address andras) internal view returns (ReactorSnapshot memory) {
        return reactorHistory[getLastSnapshotIndexOf(andras)];
    }

    function canWithdraw(address andras) external view returns (bool) {
        return sulfide[andras].epochTimerStart.add(withdrawLockupEpochs) <= treasury.epoch();
    }

    function canClaimReward(address andras) external view returns (bool) {
        return sulfide[andras].epochTimerStart.add(rewardLockupEpochs) <= treasury.epoch();
    }

    function epoch() external view returns (uint256) {
        return treasury.epoch();
    }

    function nextEpochPoint() external view returns (uint256) {
        return treasury.nextEpochPoint();
    }

    function getcataPrice() external view returns (uint256) {
        return treasury.getcataPrice();
    }

    // =========== Andras getters =========== //

    function rewardPerShare() public view returns (uint256) {
        return getLatestSnapshot().rewardPerShare;
    }

    function earned(address andras) public view returns (uint256) {
        uint256 latestRPS = getLatestSnapshot().rewardPerShare;
        uint256 storedRPS = getLastSnapshotOf(andras).rewardPerShare;

        return balanceOf(andras).mul(latestRPS.sub(storedRPS)).div(1e18).add(sulfide[andras].rewardEarned);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function stake(uint256 amount) public override onlyOneBlock updateReward(msg.sender) {
        require(amount > 0, "Reactor: Cannot stake 0");
        super.stake(amount);
        sulfide[msg.sender].epochTimerStart = treasury.epoch(); // reset timer
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public override onlyOneBlock oxideExists updateReward(msg.sender) {
        require(amount > 0, "Reactor: Cannot withdraw 0");
        require(sulfide[msg.sender].epochTimerStart.add(withdrawLockupEpochs) <= treasury.epoch(), "Reactor: still in withdraw lockup");
        claimReward();
        super.withdraw(amount);
        emit Withdrawn(msg.sender, amount);
    }

    function exit() external {
        withdraw(balanceOf(msg.sender));
    }

    function claimReward() public updateReward(msg.sender) {
        uint256 reward = sulfide[msg.sender].rewardEarned;
        if (reward > 0) {
            require(sulfide[msg.sender].epochTimerStart.add(rewardLockupEpochs) <= treasury.epoch(), "Reactor: still in reward lockup");
            sulfide[msg.sender].epochTimerStart = treasury.epoch(); // reset timer
            sulfide[msg.sender].rewardEarned = 0;
            cata.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function allocateSeigniorage(uint256 amount) external onlyOneBlock onlyOperator {
        require(amount > 0, "Reactor: Cannot allocate 0");
        require(totalSupply() > 0, "Reactor: Cannot allocate when totalSupply is 0");

        // Create & add new snapshot
        uint256 prevRPS = getLatestSnapshot().rewardPerShare;
        uint256 nextRPS = prevRPS.add(amount.mul(1e18).div(totalSupply()));

        ReactorSnapshot memory newSnapshot = ReactorSnapshot({
            time: block.number,
            rewardReceived: amount,
            rewardPerShare: nextRPS
        });
        reactorHistory.push(newSnapshot);

        cata.safeTransferFrom(msg.sender, address(this), amount);
        emit RewardAdded(msg.sender, amount);
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 _amount, address _to) external onlyOperator {
        // do not allow to drain core tokens
        require(address(_token) != address(cata), "cata");
        require(address(_token) != address(lyst), "lyst");
        _token.safeTransfer(_to, _amount);
    }
}