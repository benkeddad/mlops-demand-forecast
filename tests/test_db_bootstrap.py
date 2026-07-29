import re
from unittest.mock import MagicMock, patch

from app.db_bootstrap import bootstrap_databases


@patch("app.db_bootstrap.psycopg2.connect")
def test_bootstrap_creates_only_missing_databases(mock_connect):
    mock_cursor = MagicMock()
    mock_connect.return_value.cursor.return_value = mock_cursor
    # mlflow already exists, the other three don't
    mock_cursor.fetchone.side_effect = [(1,), None, None, None]

    bootstrap_databases()

    # CREATE DATABASE is issued as a single already-interpolated f-string
    # (psycopg2 refuses parameterized identifiers here), so pull the db
    # name back out of the SQL text itself rather than a bind-params tuple.
    created = set()
    for call in mock_cursor.execute.call_args_list:
        sql = call.args[0]
        match = re.search(r'CREATE DATABASE "(\w+)"', sql)
        if match:
            created.add(match.group(1))
    assert created == {"prefect", "feast", "rossmann"}


@patch("app.db_bootstrap.psycopg2.connect")
def test_bootstrap_creates_nothing_when_all_databases_exist(mock_connect):
    mock_cursor = MagicMock()
    mock_connect.return_value.cursor.return_value = mock_cursor
    mock_cursor.fetchone.return_value = (1,)

    bootstrap_databases()

    create_calls = [
        call for call in mock_cursor.execute.call_args_list
        if "CREATE DATABASE" in call.args[0]
    ]
    assert create_calls == []


@patch("app.db_bootstrap.psycopg2.connect")
def test_bootstrap_runs_in_autocommit_mode(mock_connect):
    # CREATE DATABASE cannot run inside a transaction block in PostgreSQL -
    # this is the specific bug this idempotent check exists to avoid.
    from psycopg2.extensions import ISOLATION_LEVEL_AUTOCOMMIT

    mock_cursor = MagicMock()
    mock_conn = mock_connect.return_value
    mock_conn.cursor.return_value = mock_cursor
    mock_cursor.fetchone.return_value = (1,)

    bootstrap_databases()

    mock_conn.set_isolation_level.assert_called_once_with(ISOLATION_LEVEL_AUTOCOMMIT)


@patch("app.db_bootstrap.psycopg2.connect")
def test_bootstrap_closes_cursor_and_connection(mock_connect):
    mock_cursor = MagicMock()
    mock_conn = mock_connect.return_value
    mock_conn.cursor.return_value = mock_cursor
    mock_cursor.fetchone.return_value = (1,)

    bootstrap_databases()

    mock_cursor.close.assert_called_once()
    mock_conn.close.assert_called_once()
