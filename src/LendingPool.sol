// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IOracle {
    function getLatestPrice() external view returns (uint256);
}

contract LendingPool is Pausable, Ownable {
    uint256 public constant COLLATERAL_FACTOR_BPS = 7500;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    IOracle public immutable ORACLE;
    address public responder;

    mapping(address => uint256) public collateral;
    mapping(address => uint256) public debt;

    event ResponderUpdated(address indexed newResponder);
    event CollateralDeposited(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount, uint256 price);
    event Repaid(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event LiquidityFunded(address indexed sender, uint256 amount);
    event EmergencyPaused(address indexed responder);
    event EmergencyUnpaused(address indexed owner);

    constructor(address owner_, address oracle_) Ownable(owner_) {
        require(owner_ != address(0), "zero owner");
        require(oracle_ != address(0), "zero oracle");
        ORACLE = IOracle(oracle_);
    }

    modifier onlyResponder() {
        require(msg.sender == responder, "not responder");
        _;
    }

    receive() external payable {
        emit LiquidityFunded(msg.sender, msg.value);
    }

    function setResponder(address newResponder) external onlyOwner {
        require(newResponder != address(0), "zero responder");
        responder = newResponder;
        emit ResponderUpdated(newResponder);
    }

    function fundLiquidity() external payable onlyOwner {
        require(msg.value > 0, "zero amount");
        emit LiquidityFunded(msg.sender, msg.value);
    }

    function depositCollateral() external payable whenNotPaused {
        require(msg.value > 0, "zero deposit");
        collateral[msg.sender] += msg.value;
        emit CollateralDeposited(msg.sender, msg.value);
    }

    function borrow(uint256 amount) external whenNotPaused {
        require(amount > 0, "zero amount");
        require(amount <= address(this).balance, "insufficient liquidity");

        uint256 price = ORACLE.getLatestPrice();
        require(price > 0, "invalid price");

        uint256 maxBorrow = (collateral[msg.sender] *
            price *
            COLLATERAL_FACTOR_BPS) / (1e18 * BPS_DENOMINATOR);

        require(debt[msg.sender] + amount <= maxBorrow, "exceeds borrow power");

        debt[msg.sender] += amount;

        (bool sent, ) = payable(msg.sender).call{value: amount}("");
        require(sent, "transfer failed");

        emit Borrowed(msg.sender, amount, price);
    }

    function repay() external payable {
        require(msg.value > 0, "zero repay");
        require(debt[msg.sender] > 0, "no debt");

        uint256 payment = msg.value > debt[msg.sender]
            ? debt[msg.sender]
            : msg.value;
        debt[msg.sender] -= payment;

        // any excess remains in pool for simplicity
        emit Repaid(msg.sender, payment);
    }

    function withdrawCollateral(uint256 amount) external whenNotPaused {
        require(amount > 0, "zero amount");
        require(collateral[msg.sender] >= amount, "insufficient collateral");

        collateral[msg.sender] -= amount;

        uint256 price = ORACLE.getLatestPrice();
        require(price > 0, "invalid price");

        uint256 maxBorrow = (collateral[msg.sender] *
            price *
            COLLATERAL_FACTOR_BPS) / (1e18 * BPS_DENOMINATOR);

        require(debt[msg.sender] <= maxBorrow, "would become insolvent");

        (bool sent, ) = payable(msg.sender).call{value: amount}("");
        require(sent, "transfer failed");

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

    function getTvl() external view returns (uint256) {
        return address(this).balance;
    }

    function paused() public view override returns (bool) {
        return super.paused();
    }
}
