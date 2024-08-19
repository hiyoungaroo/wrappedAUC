// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.23;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ILayerZeroEndpoint} from "./interfaces/ILayerZeroEndpoint.sol";
import {ILayerZeroReceiver} from "./interfaces/ILayerZeroReceiver.sol";

/// @dev wrapper contract to be deployed to other dst chains
contract WrappedAUC is ERC20, Ownable, ILayerZeroReceiver {
    /*///////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    uint16 public immutable LZ_CHAIN_ID;

    /// @dev not declared as constant to prevent vendor lock-in
    ILayerZeroEndpoint public endpoint;

    /// @dev mapping trusted remote
    mapping(uint16 => bytes) public trustedRemote;

    /// @dev total src chain tx counter
    uint256 public txCounter;

    /// @dev map nonce to processed state to prevent replay attack
    mapping(bytes => mapping(uint16 => mapping(uint64 => bool))) public nonceStatus;

    /// @dev transfer fees per tx
    uint256 public transferFeePercent = 50;

    /*///////////////////////////////////////////////////////////////
                                MODIFIER
    //////////////////////////////////////////////////////////////*/
    modifier onlyEndpoint() {
        require(msg.sender == address(endpoint), "wrapper/caller-not-endpoint");
        _;
    }

    /*///////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    event BridgingInitiated(
        uint16 srcChainId, uint16 dstChainId, uint256 srcTxIndex, address indexed receiver, uint256 amount, uint256 fees
    );
    event BridgingCompleted(
        uint16 srcChainId, uint16 dstChainId, uint256 srcTxIndex, address indexed receiver, uint256 amount
    );

    event EndpointUpdated(address indexed oldEndpoint, address indexed newEndpoint);
    event TrustedRemoteUpdated(uint16 indexed dstChainId, bytes trustedRemote);

    /// @dev emitted when transfer fees are updated.
    event TransferFeeUpdated(uint256 oldFees, uint256 newFees);

    /*///////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(uint16 _lzChainId, address _endpoint, string memory _name, string memory _symbol)
        ERC20(_name, _symbol)
        Ownable(msg.sender)
    {
        LZ_CHAIN_ID = _lzChainId;
        endpoint = ILayerZeroEndpoint(_endpoint);

        emit EndpointUpdated(address(0), _endpoint);
    }

    /*///////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Initiates a cross-chain token transfer.
    /// @param _receiver The recipient's address on the destination chain.
    /// @param _amount The amount of tokens to transfer.
    /// @param _dstChainId The destination chain's ID.
    /// @param _adapterParams Additional adapter parameters.
    function xChainTransfer(address _receiver, uint256 _amount, uint16 _dstChainId, bytes memory _adapterParams)
        external
        payable
    {
        require(trustedRemote[_dstChainId].length > 0, "bridge/invalid-dst-chain-id");

        uint256 balanceBefore = balanceOf(msg.sender);
        require(balanceBefore >= _amount, "wrapper/insufficient-balance");

        _burn(msg.sender, _amount);
        uint256 balanceAfter = balanceOf(msg.sender);

        require(balanceBefore - balanceAfter == _amount, "wrapper/burn-failed");

        uint256 fees = (_amount * transferFeePercent) / 10000;
        uint256 finalAmount = _amount - fees;

        ++txCounter;
        endpoint.send{value: msg.value}(
            _dstChainId,
            trustedRemote[_dstChainId],
            abi.encode(_receiver, finalAmount, txCounter),
            payable(msg.sender),
            address(0),
            _adapterParams
        );
        emit BridgingInitiated(LZ_CHAIN_ID, _dstChainId, txCounter, _receiver, finalAmount, fees);
    }

    /*///////////////////////////////////////////////////////////////
                              AUTH FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Updates the LayerZero endpoint contract address.
    /// @param _newEndpoint The new endpoint contract address.
    function updateEndpoint(address _newEndpoint) external onlyOwner {
        address oldEndpoint = address(endpoint);
        endpoint = ILayerZeroEndpoint(_newEndpoint);

        emit EndpointUpdated(oldEndpoint, _newEndpoint);
    }

    /// @notice Sets a trusted remote address for a destination chain.
    /// @param _dstChainId The destination chain's ID.
    /// @param _trustedRemote The trusted remote address.
    function setTrustedRemote(uint16 _dstChainId, bytes memory _trustedRemote) external onlyOwner {
        trustedRemote[_dstChainId] = _trustedRemote;

        emit TrustedRemoteUpdated(_dstChainId, _trustedRemote);
    }

    /// @notice Sets the transfer fee per transaction
    /// @param _transferFeePercent the transfer fee percent (eg: 100% = 10000)
    function setTransferFees(uint256 _transferFeePercent) external onlyOwner {
        uint256 oldFees = transferFeePercent;
        transferFeePercent = _transferFeePercent;

        emit TransferFeeUpdated(oldFees, _transferFeePercent);
    }

    /// @dev generic config for LayerZero user Application
    function setConfig(uint16 _version, uint16 _chainId, uint256 _configType, bytes calldata _config)
        external
        onlyOwner
    {
        endpoint.setConfig(_version, _chainId, _configType, _config);
    }

    function setSendVersion(uint16 _version) external onlyOwner {
        endpoint.setSendVersion(_version);
    }

    function setReceiveVersion(uint16 _version) external onlyOwner {
        endpoint.setReceiveVersion(_version);
    }

    function forceResumeReceive(uint16 _srcChainId, bytes calldata _srcAddress) external onlyOwner {
        endpoint.forceResumeReceive(_srcChainId, _srcAddress);
    }

    /*///////////////////////////////////////////////////////////////
                        EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function estimateFees(address _receiver, uint256 _amount, uint16 _dstChainId, bytes memory _adapterParams)
        external
        view
        returns (uint256)
    {
        bytes memory message = abi.encode(_receiver, _amount, txCounter);
        (uint256 fees,) = endpoint.estimateFees(_dstChainId, address(this), message, false, _adapterParams);
        return fees;
    }

    /*///////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Handles the reception of tokens on the LayerZero chain.
    /// @param _srcChainId The source chain's ID.
    /// @param _srcAddress The source address on the source chain.
    /// @param _nonce The nonce of the transaction.
    /// @param _payload The payload containing receiver, amount, and transaction ID.
    function lzReceive(uint16 _srcChainId, bytes calldata _srcAddress, uint64 _nonce, bytes calldata _payload)
        external
        onlyEndpoint
    {
        require(_srcAddress.length == trustedRemote[_srcChainId].length, "wrapper/invalid-src-sender-length");
        require(keccak256(_srcAddress) == keccak256(trustedRemote[_srcChainId]), "wrapper/invalid-src-sender");
        require(!nonceStatus[_srcAddress][_srcChainId][_nonce], "wrapper/invalid-nonce");

        nonceStatus[_srcAddress][_srcChainId][_nonce] = true;
        (address receiver, uint256 amount, uint256 srcTxId) = abi.decode(_payload, (address, uint256, uint256));
        _mint(receiver, amount);

        emit BridgingCompleted(_srcChainId, LZ_CHAIN_ID, srcTxId, receiver, amount);
    }
}
