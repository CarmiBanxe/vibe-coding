import pytest

# test_suite.py uses a custom asyncio runner (asyncio.run(run_all())).
# pytest-asyncio needs this to handle async test functions.
pytest_plugins = ["pytest_asyncio"]


def pytest_configure(config):
    config.addinivalue_line(
        "markers", "asyncio: mark test as async"
    )
