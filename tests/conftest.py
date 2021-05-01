import pytest
from brownie import config, Contract, Strategy, accounts, interface

fixtures = "currency", "interestToken", "pid", "whale"
params = [
    pytest.param(
        "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c",
        "0xd7D069493685A581d27824Fc46EdA46B7EfC0063",
        1,
        "0x0eD7e52944161450477ee417DE9Cd3a859b14fD0",
        id="WBNB",
    ),
    pytest.param(
        "0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56",
        "0x7C9e73d4C71dae564d41F78d56439bB4ba87592f",
        3,
        "0x631Fc1EA2270e98fbD9D92658eCe0F5a269Aa161",
        id="BUSD",
    ),
    pytest.param(
        "0x2170Ed0880ac9A755fd29B2688956BD959F933F8",
        "0xbfF4a34A4644a113E8200D7F1D79b3555f723AfE",
        9,
        "0x631Fc1EA2270e98fbD9D92658eCe0F5a269Aa161",
        id="ETH",
    ),
    pytest.param(
        "0x8F0528cE5eF7B51152A59745bEfDD91D97091d2F",
        "0xf1bE8ecC990cBcb90e166b71E368299f0116d421",
        11,
        "0x18B4500ebFE39AE1e13A03915C2ab0D62A1430A2",
        id="ALPACA",
    ),
]


@pytest.fixture
def andre(accounts):
    # Andre, giver of tokens, and maker of yield
    yield accounts[0]


@pytest.fixture
def gov(accounts):
    # yearn multis... I mean YFI governance. I swear!
    yield accounts[1]


@pytest.fixture
def guardian(accounts):
    # YFI Whale, probably
    yield accounts[2]


@pytest.fixture
def strategist(accounts):
    # You! Our new Strategist!
    yield accounts[3]


@pytest.fixture
def keeper(accounts):
    # This is our trusty bot!
    yield accounts[4]


@pytest.fixture
def bob(accounts):
    yield accounts[5]


@pytest.fixture
def alice(accounts):
    yield accounts[6]


@pytest.fixture
def rewards(gov):
    yield gov  # TODO: Add rewards contract


@pytest.fixture
def currency(request):
    # this one is 3EPS
    yield interface.ERC20(request.param)


@pytest.fixture
def interestToken(request):
    # this one is 3EPS
    yield interface.ERC20(request.param)


@pytest.fixture
def pid(request):
    yield request.param


@pytest.fixture
def whale(request, currency):
    acc = accounts.at(request.param, force=True)
    requiredBal = 100_000_100 * 1e18
    # if currency.balanceOf(acc) < requiredBal and currency == currencyfUSDTLP:
    #     minter = accounts.at("0x556ea0b4c06D043806859c9490072FaadC104b63", force=True)
    #     currency.mint(acc, requiredBal, {"from": minter})
    yield acc


@pytest.fixture
def vault(pm, gov, rewards, guardian, currency):
    Vault = pm(config["dependencies"][0]).Vault
    vault = gov.deploy(Vault)
    vault.initialize(currency, gov, rewards, "", "", guardian)
    vault.setManagementFee(0, {"from": gov})
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    yield vault


@pytest.fixture
def strategy(strategist, keeper, vault, Strategy, interestToken, pid):
    strategy = strategist.deploy(Strategy, vault, interestToken, pid)
    strategy.setKeeper(keeper)
    yield strategy
