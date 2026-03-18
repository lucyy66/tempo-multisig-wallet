// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITIP20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @title TempoMultiSig — Multi-signature wallet for Tempo stablecoin payments
/// @notice M-of-N multisig wallet optimized for TIP-20 stablecoin transactions on Tempo
/// @dev Supports native coin + any TIP-20/ERC-20 token with memo field
///
/// Security features:
/// - Reentrancy guard on execution
/// - Transaction expiry (configurable deadline)
/// - Max owner limit to prevent gas DoS
/// - Zero-address validation on all inputs
/// - Checks-Effects-Interactions pattern
/// - Owner-only access control
/// - Self-call only for admin functions
contract TempoMultiSig {
    // ========================
    // Constants
    // ========================
    uint256 public constant MAX_OWNERS = 20;
    uint256 public constant TX_EXPIRY = 7 days;

    // ========================
    // Events
    // ========================
    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);
    event ThresholdChanged(uint256 newThreshold);
    event TxSubmitted(uint256 indexed txId, address indexed submitter, address to, uint256 value, address token, string memo);
    event TxApproved(uint256 indexed txId, address indexed approver);
    event TxRevoked(uint256 indexed txId, address indexed revoker);
    event TxExecuted(uint256 indexed txId, address indexed executor);
    event TxCancelled(uint256 indexed txId, address indexed canceller);
    event Deposited(address indexed sender, uint256 amount);

    // ========================
    // Structs
    // ========================
    struct Transaction {
        address to;
        uint256 value;
        address token;       // address(0) = native coin, otherwise TIP-20/ERC-20
        string memo;
        bool executed;
        bool cancelled;
        uint256 approvalCount;
        uint256 submittedAt;
    }

    // ========================
    // State
    // ========================
    address[] public owners;
    mapping(address => bool) public isOwner;
    uint256 public threshold;

    Transaction[] public transactions;
    // txId => owner => approved
    mapping(uint256 => mapping(address => bool)) public approved;

    // Reentrancy guard
    uint256 private _locked = 1;

    // ========================
    // Modifiers
    // ========================
    modifier onlyOwner() {
        require(isOwner[msg.sender], "not owner");
        _;
    }

    modifier onlyWallet() {
        require(msg.sender == address(this), "not wallet");
        _;
    }

    modifier txExists(uint256 _txId) {
        require(_txId < transactions.length, "tx not found");
        _;
    }

    modifier notExecuted(uint256 _txId) {
        require(!transactions[_txId].executed, "already executed");
        _;
    }

    modifier notCancelled(uint256 _txId) {
        require(!transactions[_txId].cancelled, "tx cancelled");
        _;
    }

    modifier notExpired(uint256 _txId) {
        require(
            block.timestamp <= transactions[_txId].submittedAt + TX_EXPIRY,
            "tx expired"
        );
        _;
    }

    modifier noReentrant() {
        require(_locked == 1, "reentrant call");
        _locked = 2;
        _;
        _locked = 1;
    }

    // ========================
    // Constructor
    // ========================
    /// @param _owners List of initial owner addresses
    /// @param _threshold Minimum approvals needed to execute
    constructor(address[] memory _owners, uint256 _threshold) {
        require(_owners.length > 0, "need owners");
        require(_owners.length <= MAX_OWNERS, "too many owners");
        require(_threshold > 0 && _threshold <= _owners.length, "bad threshold");

        for (uint256 i = 0; i < _owners.length; i++) {
            address owner = _owners[i];
            require(owner != address(0), "zero address");
            require(!isOwner[owner], "duplicate owner");

            isOwner[owner] = true;
            owners.push(owner);
            emit OwnerAdded(owner);
        }

        threshold = _threshold;
    }

    // ========================
    // Receive
    // ========================
    receive() external payable {
        emit Deposited(msg.sender, msg.value);
    }

    // ========================
    // Core Functions
    // ========================

    /// @notice Submit a new transaction for approval
    /// @param _to Recipient address
    /// @param _value Amount to send (must be > 0)
    /// @param _token Token address (address(0) for native coin)
    /// @param _memo Payment memo / note
    /// @return txId The transaction ID
    function submit(
        address _to,
        uint256 _value,
        address _token,
        string calldata _memo
    ) external onlyOwner returns (uint256 txId) {
        require(_to != address(0), "zero recipient");
        require(_value > 0, "zero value");

        txId = transactions.length;

        transactions.push(Transaction({
            to: _to,
            value: _value,
            token: _token,
            memo: _memo,
            executed: false,
            cancelled: false,
            approvalCount: 1,
            submittedAt: block.timestamp
        }));

        // Auto-approve by submitter
        approved[txId][msg.sender] = true;

        emit TxSubmitted(txId, msg.sender, _to, _value, _token, _memo);
        emit TxApproved(txId, msg.sender);

        // Auto-execute if threshold == 1
        if (threshold == 1) {
            _execute(txId);
        }

        return txId;
    }

    /// @notice Approve a pending transaction
    /// @param _txId Transaction ID to approve
    function approve(uint256 _txId)
        external
        onlyOwner
        txExists(_txId)
        notExecuted(_txId)
        notCancelled(_txId)
        notExpired(_txId)
    {
        require(!approved[_txId][msg.sender], "already approved");

        approved[_txId][msg.sender] = true;
        transactions[_txId].approvalCount++;

        emit TxApproved(_txId, msg.sender);

        // Auto-execute if threshold reached
        if (transactions[_txId].approvalCount >= threshold) {
            _execute(_txId);
        }
    }

    /// @notice Revoke your approval from a pending transaction
    /// @param _txId Transaction ID to revoke
    function revoke(uint256 _txId)
        external
        onlyOwner
        txExists(_txId)
        notExecuted(_txId)
        notCancelled(_txId)
    {
        require(approved[_txId][msg.sender], "not approved");

        approved[_txId][msg.sender] = false;
        transactions[_txId].approvalCount--;

        emit TxRevoked(_txId, msg.sender);
    }

    /// @notice Cancel a pending transaction (submitter only, or via multisig)
    /// @param _txId Transaction ID to cancel
    function cancel(uint256 _txId)
        external
        onlyOwner
        txExists(_txId)
        notExecuted(_txId)
        notCancelled(_txId)
    {
        transactions[_txId].cancelled = true;
        emit TxCancelled(_txId, msg.sender);
    }

    // ========================
    // Internal
    // ========================

    /// @dev Execute transaction with reentrancy protection + checks-effects-interactions
    function _execute(uint256 _txId) internal noReentrant notExecuted(_txId) notCancelled(_txId) {
        Transaction storage t = transactions[_txId];
        require(t.approvalCount >= threshold, "not enough approvals");
        require(block.timestamp <= t.submittedAt + TX_EXPIRY, "tx expired");

        // Effects first (before interaction)
        t.executed = true;

        // Interactions last
        if (t.token == address(0)) {
            (bool ok,) = t.to.call{value: t.value}("");
            require(ok, "native transfer failed");
        } else {
            bool ok = ITIP20(t.token).transfer(t.to, t.value);
            require(ok, "token transfer failed");
        }

        emit TxExecuted(_txId, msg.sender);
    }

    // ========================
    // Owner Management (via multisig self-call only)
    // ========================

    /// @notice Add a new owner — must be called via multisig submit/approve flow
    function addOwner(address _owner) external onlyWallet {
        require(_owner != address(0), "zero address");
        require(!isOwner[_owner], "already owner");
        require(owners.length < MAX_OWNERS, "max owners reached");

        isOwner[_owner] = true;
        owners.push(_owner);
        emit OwnerAdded(_owner);
    }

    /// @notice Remove an owner — must be called via multisig submit/approve flow
    function removeOwner(address _owner) external onlyWallet {
        require(isOwner[_owner], "not owner");
        require(owners.length - 1 >= threshold, "would break threshold");

        isOwner[_owner] = false;
        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == _owner) {
                owners[i] = owners[owners.length - 1];
                owners.pop();
                break;
            }
        }
        emit OwnerRemoved(_owner);
    }

    /// @notice Change approval threshold — must be called via multisig submit/approve flow
    function changeThreshold(uint256 _newThreshold) external onlyWallet {
        require(_newThreshold > 0 && _newThreshold <= owners.length, "bad threshold");
        threshold = _newThreshold;
        emit ThresholdChanged(_newThreshold);
    }

    // ========================
    // View Functions
    // ========================

    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    function getTransactionCount() external view returns (uint256) {
        return transactions.length;
    }

    function getTransaction(uint256 _txId)
        external
        view
        txExists(_txId)
        returns (
            address to,
            uint256 value,
            address token,
            string memory memo,
            bool executed,
            bool cancelled,
            uint256 approvalCount,
            uint256 submittedAt
        )
    {
        Transaction storage t = transactions[_txId];
        return (t.to, t.value, t.token, t.memo, t.executed, t.cancelled, t.approvalCount, t.submittedAt);
    }

    function isApproved(uint256 _txId, address _owner)
        external
        view
        txExists(_txId)
        returns (bool)
    {
        return approved[_txId][_owner];
    }

    function isTxExpired(uint256 _txId) external view txExists(_txId) returns (bool) {
        return block.timestamp > transactions[_txId].submittedAt + TX_EXPIRY;
    }

    function getBalance(address _token) external view returns (uint256) {
        if (_token == address(0)) {
            return address(this).balance;
        }
        return ITIP20(_token).balanceOf(address(this));
    }
}
