// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OracleManipulationTrap} from "./OracleManipulationTrap.sol";

contract TestableOracleManipulationTrap is OracleManipulationTrap {
    address public immutable ORACLE_TEST;
    address public immutable POOL_TEST;

    constructor(address oracle_, address pool_) {
        require(oracle_ != address(0), "oracle zero");
        require(pool_ != address(0), "pool zero");

        ORACLE_TEST = oracle_;
        POOL_TEST = pool_;
    }

    function collect() external view override returns (bytes memory) {
        return _collectFrom(ORACLE_TEST, POOL_TEST);
    }
}
