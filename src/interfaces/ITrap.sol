// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title ITrap
 * @notice Drosera trap interface
 */
interface ITrap {
    /**
     * @notice Collect current state snapshot
     * @return Encoded snapshot (chain-specific format)
     */
    function collect() external view returns (bytes memory);

    /**
     * @notice Determine if trap should trigger
     * @param data Array of encoded historical snapshots
     * @return (shouldTrigger, responsePayload)
     */
    function shouldRespond(
        bytes[] calldata data
    ) external pure returns (bool, bytes memory);
}
