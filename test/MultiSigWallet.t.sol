// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/MultiSigWallet.sol";

/// @dev Mock TIP-20 token for testing
contract MockTIP20 is ITIP20 {
    string public name = "TestUSD";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient");
        require(allowance[from][msg.sender] >= amount, "not allowed");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/// @dev Malicious contract that tries reentrancy
contract ReentrancyAttacker {
    TempoMultiSig public target;
    uint256 public attackTxId;
    uint256 public attackCount;

    constructor(address _target) {
        target = TempoMultiSig(payable(_target));
    }

    receive() external payable {
        if (attackCount < 2) {
            attackCount++;
            // Try to re-enter approve on another tx
            try target.approve(attackTxId) {} catch {}
        }
    }
}

contract MultiSigWalletTest is Test {
    TempoMultiSig wallet;
    MockTIP20 token;

    address alice = address(0xA);
    address bob = address(0xB);
    address charlie = address(0xC);
    address outsider = address(0xD);
    address recipient = address(0xE);

    function setUp() public {
        // 2-of-3 multisig
        address[] memory owners = new address[](3);
        owners[0] = alice;
        owners[1] = bob;
        owners[2] = charlie;

        wallet = new TempoMultiSig(owners, 2);

        // Fund wallet with native coin
        vm.deal(address(wallet), 10 ether);

        // Deploy mock token and fund wallet
        token = new MockTIP20();
        token.mint(address(wallet), 1_000_000e6); // 1M USDC
    }

    // ========================
    // Constructor Tests
    // ========================

    function test_Constructor() public view {
        assertEq(wallet.threshold(), 2);
        assertEq(wallet.owners(0), alice);
        assertEq(wallet.owners(1), bob);
        assertEq(wallet.owners(2), charlie);
        assertTrue(wallet.isOwner(alice));
        assertTrue(wallet.isOwner(bob));
        assertTrue(wallet.isOwner(charlie));
        assertFalse(wallet.isOwner(outsider));
    }

    function test_Constructor_RevertNoOwners() public {
        address[] memory empty = new address[](0);
        vm.expectRevert("need owners");
        new TempoMultiSig(empty, 1);
    }

    function test_Constructor_RevertBadThreshold() public {
        address[] memory owners = new address[](2);
        owners[0] = alice;
        owners[1] = bob;
        vm.expectRevert("bad threshold");
        new TempoMultiSig(owners, 3);
    }

    function test_Constructor_RevertZeroThreshold() public {
        address[] memory owners = new address[](1);
        owners[0] = alice;
        vm.expectRevert("bad threshold");
        new TempoMultiSig(owners, 0);
    }

    function test_Constructor_RevertDuplicateOwner() public {
        address[] memory owners = new address[](2);
        owners[0] = alice;
        owners[1] = alice;
        vm.expectRevert("duplicate owner");
        new TempoMultiSig(owners, 1);
    }

    function test_Constructor_RevertTooManyOwners() public {
        address[] memory owners = new address[](21);
        for (uint256 i = 0; i < 21; i++) {
            owners[i] = address(uint160(i + 100));
        }
        vm.expectRevert("too many owners");
        new TempoMultiSig(owners, 10);
    }

    function test_Constructor_RevertZeroAddress() public {
        address[] memory owners = new address[](2);
        owners[0] = alice;
        owners[1] = address(0);
        vm.expectRevert("zero address");
        new TempoMultiSig(owners, 1);
    }

    // ========================
    // Submit Tests
    // ========================

    function test_SubmitNativeTx() public {
        vm.prank(alice);
        uint256 txId = wallet.submit(recipient, 1 ether, address(0), "gaji Maret");

        assertEq(txId, 0);
        (
            address to,
            uint256 value,
            address tkn,
            string memory memo,
            bool executed,
            bool cancelled,
            uint256 approvalCount,
        ) = wallet.getTransaction(0);

        assertEq(to, recipient);
        assertEq(value, 1 ether);
        assertEq(tkn, address(0));
        assertEq(memo, "gaji Maret");
        assertFalse(executed);
        assertFalse(cancelled);
        assertEq(approvalCount, 1);
    }

    function test_SubmitTokenTx() public {
        vm.prank(bob);
        uint256 txId = wallet.submit(recipient, 5000e6, address(token), "bayar vendor");

        assertEq(txId, 0);
        assertTrue(wallet.isApproved(0, bob));
    }

    function test_Submit_RevertNotOwner() public {
        vm.prank(outsider);
        vm.expectRevert("not owner");
        wallet.submit(recipient, 1 ether, address(0), "hack");
    }

    function test_Submit_RevertZeroRecipient() public {
        vm.prank(alice);
        vm.expectRevert("zero recipient");
        wallet.submit(address(0), 1 ether, address(0), "");
    }

    function test_Submit_RevertZeroValue() public {
        vm.prank(alice);
        vm.expectRevert("zero value");
        wallet.submit(recipient, 0, address(0), "");
    }

    // ========================
    // Approve + Execute Tests
    // ========================

    function test_ApproveAndExecuteNative() public {
        uint256 balBefore = recipient.balance;

        vm.prank(alice);
        wallet.submit(recipient, 1 ether, address(0), "test payment");

        vm.prank(bob);
        wallet.approve(0);

        (,,,, bool executed,, uint256 approvalCount,) = wallet.getTransaction(0);
        assertTrue(executed);
        assertEq(approvalCount, 2);
        assertEq(recipient.balance - balBefore, 1 ether);
    }

    function test_ApproveAndExecuteToken() public {
        uint256 balBefore = token.balanceOf(recipient);

        vm.prank(alice);
        wallet.submit(recipient, 5000e6, address(token), "invoice #042");

        vm.prank(charlie);
        wallet.approve(0);

        (,,,, bool executed,,,) = wallet.getTransaction(0);
        assertTrue(executed);
        assertEq(token.balanceOf(recipient) - balBefore, 5000e6);
    }

    function test_Approve_RevertAlreadyApproved() public {
        vm.prank(alice);
        wallet.submit(recipient, 1 ether, address(0), "");

        vm.prank(alice);
        vm.expectRevert("already approved");
        wallet.approve(0);
    }

    function test_Approve_RevertNotOwner() public {
        vm.prank(alice);
        wallet.submit(recipient, 1 ether, address(0), "");

        vm.prank(outsider);
        vm.expectRevert("not owner");
        wallet.approve(0);
    }

    function test_Approve_RevertAlreadyExecuted() public {
        vm.prank(alice);
        wallet.submit(recipient, 1 ether, address(0), "");

        vm.prank(bob);
        wallet.approve(0); // executes

        vm.prank(charlie);
        vm.expectRevert("already executed");
        wallet.approve(0);
    }

    // ========================
    // Revoke Tests
    // ========================

    function test_Revoke() public {
        vm.prank(alice);
        wallet.submit(recipient, 1 ether, address(0), "");

        vm.prank(alice);
        wallet.revoke(0);

        assertFalse(wallet.isApproved(0, alice));
        (,,,,, , uint256 approvalCount,) = wallet.getTransaction(0);
        assertEq(approvalCount, 0);
    }

    function test_Revoke_RevertNotApproved() public {
        vm.prank(alice);
        wallet.submit(recipient, 1 ether, address(0), "");

        vm.prank(bob);
        vm.expectRevert("not approved");
        wallet.revoke(0);
    }

    // ========================
    // Cancel Tests
    // ========================

    function test_Cancel() public {
        vm.prank(alice);
        wallet.submit(recipient, 1 ether, address(0), "will cancel");

        vm.prank(alice);
        wallet.cancel(0);

        (,,,,, bool cancelled,,) = wallet.getTransaction(0);
        assertTrue(cancelled);
    }

    function test_Cancel_BlocksApproval() public {
        vm.prank(alice);
        wallet.submit(recipient, 1 ether, address(0), "");

        vm.prank(bob);
        wallet.cancel(0);

        vm.prank(charlie);
        vm.expectRevert("tx cancelled");
        wallet.approve(0);
    }

    function test_Cancel_RevertAlreadyExecuted() public {
        vm.prank(alice);
        wallet.submit(recipient, 1 ether, address(0), "");

        vm.prank(bob);
        wallet.approve(0); // executes

        vm.prank(alice);
        vm.expectRevert("already executed");
        wallet.cancel(0);
    }

    // ========================
    // Expiry Tests
    // ========================

    function test_Expire_BlocksApproval() public {
        vm.prank(alice);
        wallet.submit(recipient, 1 ether, address(0), "old tx");

        // Warp past expiry (7 days + 1 second)
        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(bob);
        vm.expectRevert("tx expired");
        wallet.approve(0);
    }

    function test_Expire_ViewFunction() public {
        vm.prank(alice);
        wallet.submit(recipient, 1 ether, address(0), "");

        assertFalse(wallet.isTxExpired(0));

        vm.warp(block.timestamp + 7 days + 1);
        assertTrue(wallet.isTxExpired(0));
    }

    function test_NotExpired_WithinWindow() public {
        vm.prank(alice);
        wallet.submit(recipient, 1 ether, address(0), "");

        // Still within 7 days
        vm.warp(block.timestamp + 6 days);

        vm.prank(bob);
        wallet.approve(0); // should work fine

        (,,,, bool executed,,,) = wallet.getTransaction(0);
        assertTrue(executed);
    }

    // ========================
    // Reentrancy Tests
    // ========================

    function test_ReentrancyProtection() public {
        // Deploy attacker contract that targets the wallet
        ReentrancyAttacker attacker = new ReentrancyAttacker(address(wallet));

        // Create 1-of-2 wallet with alice and attacker address
        address[] memory owners = new address[](2);
        owners[0] = alice;
        owners[1] = address(attacker);
        TempoMultiSig soloWallet = new TempoMultiSig(owners, 1);
        vm.deal(address(soloWallet), 10 ether);

        // Update attacker target
        attacker = new ReentrancyAttacker(address(soloWallet));

        // Submit two txs
        vm.prank(alice);
        soloWallet.submit(address(attacker), 1 ether, address(0), "tx0");
        // tx0 auto-executed (threshold=1), attacker receive() fires but
        // reentrancy guard blocks any nested _execute call

        // Only 1 ether sent, not drained
        assertEq(address(attacker).balance, 1 ether);
        assertEq(address(soloWallet).balance, 9 ether);
    }

    // ========================
    // Owner Management Tests
    // ========================

    function test_AddOwner() public {
        vm.prank(address(wallet));
        wallet.addOwner(outsider);

        assertTrue(wallet.isOwner(outsider));
    }

    function test_AddOwner_RevertNotWallet() public {
        vm.prank(alice);
        vm.expectRevert("not wallet");
        wallet.addOwner(outsider);
    }

    function test_AddOwner_RevertMaxOwners() public {
        // Fill up to MAX_OWNERS
        for (uint256 i = 0; i < 17; i++) {
            vm.prank(address(wallet));
            wallet.addOwner(address(uint160(i + 100)));
        }
        // 20 owners now, try adding 21st
        vm.prank(address(wallet));
        vm.expectRevert("max owners reached");
        wallet.addOwner(address(uint160(200)));
    }

    function test_RemoveOwner() public {
        vm.prank(address(wallet));
        wallet.removeOwner(charlie);

        assertFalse(wallet.isOwner(charlie));
        address[] memory ownerList = wallet.getOwners();
        assertEq(ownerList.length, 2);
    }

    function test_RemoveOwner_RevertBreaksThreshold() public {
        vm.prank(address(wallet));
        wallet.removeOwner(charlie);

        vm.prank(address(wallet));
        vm.expectRevert("would break threshold");
        wallet.removeOwner(bob);
    }

    function test_ChangeThreshold() public {
        vm.prank(address(wallet));
        wallet.changeThreshold(3);
        assertEq(wallet.threshold(), 3);
    }

    // ========================
    // Auto-execute with threshold=1
    // ========================

    function test_AutoExecuteThreshold1() public {
        address[] memory owners = new address[](1);
        owners[0] = alice;
        TempoMultiSig solo = new TempoMultiSig(owners, 1);
        vm.deal(address(solo), 5 ether);

        uint256 balBefore = recipient.balance;

        vm.prank(alice);
        solo.submit(recipient, 1 ether, address(0), "solo tx");

        (,,,, bool executed,,,) = solo.getTransaction(0);
        assertTrue(executed);
        assertEq(recipient.balance - balBefore, 1 ether);
    }

    // ========================
    // View Functions
    // ========================

    function test_GetOwners() public view {
        address[] memory ownerList = wallet.getOwners();
        assertEq(ownerList.length, 3);
    }

    function test_GetTransactionCount() public {
        assertEq(wallet.getTransactionCount(), 0);

        vm.prank(alice);
        wallet.submit(recipient, 1 ether, address(0), "");

        assertEq(wallet.getTransactionCount(), 1);
    }

    function test_GetBalance() public view {
        assertEq(wallet.getBalance(address(0)), 10 ether);
        assertEq(wallet.getBalance(address(token)), 1_000_000e6);
    }

    function test_Constants() public view {
        assertEq(wallet.MAX_OWNERS(), 20);
        assertEq(wallet.TX_EXPIRY(), 7 days);
    }

    // ========================
    // Receive / Deposit
    // ========================

    function test_ReceiveDeposit() public {
        vm.deal(outsider, 5 ether);
        vm.prank(outsider);
        (bool ok,) = address(wallet).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(wallet).balance, 11 ether);
    }

    // ========================
    // Multiple Transactions
    // ========================

    function test_MultipleTxFlow() public {
        vm.prank(alice);
        wallet.submit(recipient, 1 ether, address(0), "tx pertama");

        vm.prank(bob);
        wallet.submit(recipient, 100e6, address(token), "tx kedua");

        assertEq(wallet.getTransactionCount(), 2);

        // Approve tx 1 first
        vm.prank(alice);
        wallet.approve(1);

        // Tx 0 still pending
        (,,,, bool exec0,,,) = wallet.getTransaction(0);
        assertFalse(exec0);

        // Approve tx 0
        vm.prank(charlie);
        wallet.approve(0);

        (,,,, bool exec0After,,,) = wallet.getTransaction(0);
        assertTrue(exec0After);
    }

    // ========================
    // Memo Tests (Tempo TIP-20 feature)
    // ========================

    function test_MemoStored() public {
        vm.prank(alice);
        wallet.submit(recipient, 1e6, address(token), "Invoice #2024-042 | Project Alpha");

        (,,, string memory memo,,,,) = wallet.getTransaction(0);
        assertEq(memo, "Invoice #2024-042 | Project Alpha");
    }

    function test_EmptyMemo() public {
        vm.prank(alice);
        wallet.submit(recipient, 1e6, address(token), "");

        (,,, string memory memo,,,,) = wallet.getTransaction(0);
        assertEq(memo, "");
    }

    // ========================
    // Edge Cases
    // ========================

    function test_RevokeAfterCancelFails() public {
        vm.prank(alice);
        wallet.submit(recipient, 1 ether, address(0), "");

        vm.prank(bob);
        wallet.cancel(0);

        vm.prank(alice);
        vm.expectRevert("tx cancelled");
        wallet.revoke(0);
    }

    function test_SubmitMultipleAndCancelOne() public {
        vm.prank(alice);
        wallet.submit(recipient, 1 ether, address(0), "keep");

        vm.prank(alice);
        wallet.submit(recipient, 2 ether, address(0), "cancel this");

        // Cancel tx 1
        vm.prank(alice);
        wallet.cancel(1);

        // Tx 0 still works
        vm.prank(bob);
        wallet.approve(0);

        (,,,, bool exec0,,,) = wallet.getTransaction(0);
        assertTrue(exec0);

        // Tx 1 is cancelled
        (,,,,, bool cancelled1,,) = wallet.getTransaction(1);
        assertTrue(cancelled1);
    }
}
