import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))

from app import app as flask_app  # noqa: E402


@pytest.fixture
def client():
    flask_app.config["TESTING"] = True
    with flask_app.test_client() as client:
        yield client


def test_health_returns_healthy(client):
    """The pipeline's deploy gate depends on this contract."""
    res = client.get("/health")
    assert res.status_code == 200
    assert res.get_json() == {"status": "healthy"}


def test_home_reports_service_live(client):
    res = client.get("/")
    assert res.status_code == 200
    body = res.get_json()
    assert body["app"] == "CloudCourt Stats API"
    assert body["status"] == "live"


def test_players_returns_list(client):
    res = client.get("/players")
    assert res.status_code == 200
    players = res.get_json()
    assert isinstance(players, list)
    assert len(players) == 3


def test_every_player_has_required_fields(client):
    players = client.get("/players").get_json()
    for player in players:
        assert "id" in player
        assert "name" in player
        assert "ppg" in player
        assert isinstance(player["ppg"], (int, float))


def test_player_ids_are_unique(client):
    players = client.get("/players").get_json()
    ids = [p["id"] for p in players]
    assert len(ids) == len(set(ids))


def test_unknown_route_404s(client):
    assert client.get("/does-not-exist").status_code == 404
