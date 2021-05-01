pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

interface IMasterChef {
    struct UserInfo {
        uint256 amount; // How many Staking tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 bonusDebt; // Last block that user exec something to the pool.
        address fundedBy; // Funded by who?
    }

    // Info of each pool.
    struct PoolInfo {
        address stakeToken; // Address of Staking token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. ALPACAs to distribute per block.
        uint256 lastRewardBlock; // Last block number that ALPACAs distribution occurs.
        uint256 accAlpacaPerShare; // Accumulated ALPACAs per share, times 1e12. See below.
        uint256 accAlpacaPerShareTilBonusEnd; // Accumated ALPACAs per share until Bonus End.
    }

    function deposit(
        address _for,
        uint256 _pid,
        uint256 _amount
    ) external;

    function withdraw(
        address _for,
        uint256 _pid,
        uint256 _amount
    ) external;

    function emergencyWithdraw(uint256 _pid) external;

    function poolInfo(uint256 _pid) external view returns (PoolInfo memory);

    function userInfo(uint256 _pid, address user) external view returns (UserInfo memory);

    function harvest(uint256 _pid) external;

    function pendingAlpaca(uint256 _pid, address _user) external view returns (uint256);
}
