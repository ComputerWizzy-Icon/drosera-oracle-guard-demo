// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IStaleCheckedOracle {
    function getLatestPrice()
        external
        view
        returns (uint256 price, uint256 updatedAt);
}

contract MockProductionLendingPool is Ownable, Pausable, ReentrancyGuard {
    uint256 public constant WAD = 1e18;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    uint256 public constant COLLATERAL_FACTOR_BPS = 7_500;
    uint256 public constant LIQUIDATION_THRESHOLD_BPS = 8_000;
    uint256 public constant LIQUIDATION_BONUS_BPS = 500;

    IStaleCheckedOracle public immutable ORACLE;

    address public responder;

    uint256 public maxOracleStaleness = 1 hours;

    uint256 public borrowRatePerBlockWad = 1e12;

    uint256 public lastAccrualBlock;
    uint256 public borrowIndex = WAD;

    uint256 public totalCollateral;
    uint256 public totalBorrows;
    uint256 public totalBadDebt;
    uint256 public accountedLiquidity;

    mapping(address => uint256) public collateral;
    mapping(address => uint256) public debtPrincipal;
    mapping(address => uint256) public userBorrowIndex;

    event ResponderUpdated(address indexed responder);
    event OracleStalenessUpdated(uint256 maxOracleStaleness);
    event BorrowRateUpdated(uint256 borrowRatePerBlockWad);

    event LiquidityFunded(address indexed sender, uint256 amount);
    event CollateralDeposited(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount, uint256 price);
    event Repaid(address indexed user, uint256 amount, uint256 refund);
    event CollateralWithdrawn(address indexed user, uint256 amount);

    event EmergencyPaused(address indexed responder);
    event EmergencyUnpaused(address indexed owner);

    modifier onlyResponder() {
        require(msg.sender == responder, "not responder");
        _;
    }

    constructor(address owner_, address oracle_) Ownable(owner_) {
        require(owner_ != address(0), "zero owner");
        require(oracle_ != address(0), "zero oracle");

        ORACLE = IStaleCheckedOracle(oracle_);
        lastAccrualBlock = block.number;
    }

    receive() external payable {
        revert("use fundLiquidity/depositCollateral/repay");
    }

    function setResponder(address newResponder) external onlyOwner {
        require(newResponder != address(0), "zero responder");
        responder = newResponder;
        emit ResponderUpdated(newResponder);
    }

    function setMaxOracleStaleness(uint256 newMaxStaleness) external onlyOwner {
        require(newMaxStaleness > 0, "zero staleness");
        maxOracleStaleness = newMaxStaleness;
        emit OracleStalenessUpdated(newMaxStaleness);
    }

    function setBorrowRatePerBlockWad(uint256 newRate) external onlyOwner {
        require(newRate <= 1e16, "rate too high");
        _accrueInterest();
        borrowRatePerBlockWad = newRate;
        emit BorrowRateUpdated(newRate);
    }

    function fundLiquidity() external payable onlyOwner nonReentrant {
        require(msg.value > 0, "zero amount");
        accountedLiquidity += msg.value;
        emit LiquidityFunded(msg.sender, msg.value);
    }

    function depositCollateral() external payable whenNotPaused nonReentrant {
        require(msg.value > 0, "zero deposit");

        collateral[msg.sender] += msg.value;
        totalCollateral += msg.value;

        emit CollateralDeposited(msg.sender, msg.value);
    }

    function borrow(uint256 amount) external whenNotPaused nonReentrant {
        require(amount > 0, "zero amount");

        _accrueInterest();
        _syncUserDebt(msg.sender);

        require(amount <= accountedLiquidity, "insufficient liquidity");

        uint256 price = _freshPrice();

        uint256 newDebt = debtPrincipal[msg.sender] + amount;
        require(
            _isSolventWithDebt(msg.sender, newDebt, price),
            "exceeds borrow power"
        );

        debtPrincipal[msg.sender] = newDebt;
        userBorrowIndex[msg.sender] = borrowIndex;

        totalBorrows += amount;
        accountedLiquidity -= amount;

        (bool sent, ) = payable(msg.sender).call{value: amount}("");
        require(sent, "eth transfer failed");

        emit Borrowed(msg.sender, amount, price);
    }

    function repay() external payable nonReentrant {
        require(msg.value > 0, "zero repay");

        _accrueInterest();
        _syncUserDebt(msg.sender);

        uint256 debt = debtPrincipal[msg.sender];
        require(debt > 0, "no debt");

        uint256 payment = msg.value > debt ? debt : msg.value;
        uint256 refund = msg.value - payment;

        debtPrincipal[msg.sender] = debt - payment;
        userBorrowIndex[msg.sender] = borrowIndex;

        totalBorrows -= payment;
        accountedLiquidity += payment;

        if (refund > 0) {
            (bool refunded, ) = payable(msg.sender).call{value: refund}("");
            require(refunded, "refund failed");
        }

        emit Repaid(msg.sender, payment, refund);
    }

    function withdrawCollateral(
        uint256 amount
    ) external whenNotPaused nonReentrant {
        require(amount > 0, "zero amount");
        require(collateral[msg.sender] >= amount, "insufficient collateral");

        _accrueInterest();
        _syncUserDebt(msg.sender);

        uint256 price = _freshPrice();

        collateral[msg.sender] -= amount;
        totalCollateral -= amount;

        require(_isSolvent(msg.sender, price), "would become insolvent");

        (bool sent, ) = payable(msg.sender).call{value: amount}("");
        require(sent, "eth transfer failed");

        emit CollateralWithdrawn(msg.sender, amount);
    }

    function emergencyPause() external onlyResponder {
        if (!paused()) {
            _pause();
            emit EmergencyPaused(msg.sender);
        }
    }

    function emergencyUnpause() external onlyOwner {
        require(paused(), "not paused");
        _unpause();
        emit EmergencyUnpaused(msg.sender);
    }

    // =========================================================
    // 🔥 FIXED TVL (REAL ECONOMIC MODEL)
    // =========================================================

    function getAvailableLiquidity() external view returns (uint256) {
        return accountedLiquidity;
    }

    function getTvl() external view returns (uint256) {
        if (accountedLiquidity < totalBorrows) {
            return 0;
        }
        return accountedLiquidity - totalBorrows;
    }

    // =========================================================
    // INTERNALS
    // =========================================================

    function _accrueInterest() internal {
        if (block.number == lastAccrualBlock) return;

        if (totalBorrows == 0) {
            lastAccrualBlock = block.number;
            return;
        }

        uint256 blocksElapsed = block.number - lastAccrualBlock;
        uint256 interestFactor = borrowRatePerBlockWad * blocksElapsed;

        uint256 interestAccrued = (totalBorrows * interestFactor) / WAD;

        totalBorrows += interestAccrued;
        borrowIndex += (borrowIndex * interestFactor) / WAD;

        lastAccrualBlock = block.number;
    }

    function _syncUserDebt(address user) internal {
        uint256 principal = debtPrincipal[user];

        if (principal == 0) {
            userBorrowIndex[user] = borrowIndex;
            return;
        }

        uint256 userIndex = userBorrowIndex[user];
        if (userIndex == 0) userIndex = WAD;

        debtPrincipal[user] = (principal * borrowIndex) / userIndex;
        userBorrowIndex[user] = borrowIndex;
    }

    function _freshPrice() internal view returns (uint256 price) {
        uint256 updatedAt;
        (price, updatedAt) = ORACLE.getLatestPrice();

        require(price > 0, "invalid price");
        require(updatedAt > 0, "invalid timestamp");
        require(
            block.timestamp <= updatedAt + maxOracleStaleness,
            "stale oracle"
        );
    }

    function _isSolvent(
        address user,
        uint256 price
    ) internal view returns (bool) {
        return _isSolventWithDebt(user, debtPrincipal[user], price);
    }

    function _isSolventWithDebt(
        address user,
        uint256 debt,
        uint256 price
    ) internal view returns (bool) {
        uint256 collateralValue = (collateral[user] * price) / WAD;
        uint256 maxBorrow = (collateralValue * COLLATERAL_FACTOR_BPS) /
            BPS_DENOMINATOR;

        return debt <= maxBorrow;
    }
}
