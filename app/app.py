from flask import Flask, jsonify

app = Flask(__name__)

players = [
    {"id": 1, "name": "Point God", "ppg": 18.4, "apg": 11.2},
    {"id": 2, "name": "Splash Wing", "ppg": 28.1, "apg": 4.1},
    {"id": 3, "name": "Rim Protector", "ppg": 12.3, "bpg": 3.5},
]

@app.route("/")
def home():
    return jsonify({"app": "CloudCourt Stats API", "status": "live"})

@app.route("/players")
def get_players():
    return jsonify(players)

@app.route("/health")
def health():
    return jsonify({"status": "healthy"})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
