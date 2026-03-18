// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/MultiSigWallet.sol";

contract DeployMultiSig is Script {
    function run() external {
        // Configure owners and threshold via env vars
        // OWNER1, OWNER2, OWNER3 = wallet addresses
        // THRESHOLD = minimum approvals needed
        address owner1 = vm.envAddress("OWNER1");
        address owner2 = vm.envAddress("OWNER2");
        address owner3 = vm.envAddress("OWNER3");
        uint256 threshold = vm.envUint("THRESHOLD");

        address[] memory owners = new address[](3);
        owners[0] = owner1;
        owners[1] = owner2;
        owners[2] = owner3;

        vm.startBroadcast();

        TempoMultiSig wallet = new TempoMultiSig(owners, threshold);

        vm.stopBroadcast();

        console.log("TempoMultiSig deployed at:", address(wallet));
        console.log("Owners:", owner1, owner2, owner3);
        console.log("Threshold:", threshold);
    }
}
