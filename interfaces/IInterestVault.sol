pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

interface IInterestVault {
    function config() external view returns (address);

    function debtToken() external view returns (address);

    function deposit(uint256 amountToken) external payable;

    function fairLaunchPoolId() external view returns (uint256);

    function pendingInterest(uint256 value) external view returns (uint256);

    function reservePool() external view returns (uint256);

    function token() external view returns (address);

    function totalToken() external view returns (uint256);

    function withdraw(uint256 share) external;

    function withdrawReserve(address to, uint256 value) external;

    function owner() external view returns (address);

    function vaultDebtVal() external view returns (uint256);
}
