# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

crAPI (Completely Ridiculous API) is an intentionally vulnerable API security training application from OWASP. It demonstrates the OWASP API Top 10 vulnerabilities through a B2C car servicing platform where users can manage vehicles, contact mechanics, shop for accessories, and participate in a community forum.

**Important:** This application is vulnerable by design for educational purposes. Do not deploy to production or expose to untrusted networks.

## Architecture

crAPI uses a microservices architecture with the following services:

| Service | Technology | Port | Purpose |
|---------|------------|------|---------|
| **web** | React + TypeScript / Nginx (OpenResty) | 8888, 8443 | Frontend SPA and API gateway |
| **identity** | Java 17 / Spring Boot 3.2 | 8080 | User authentication, JWT, vehicle management |
| **community** | Go 1.21 / Gorilla Mux | 8087 | Blog posts, comments, coupons |
| **workshop** | Python / Django 4.1 / DRF | 8000 | Mechanics, orders, shop, service requests |
| **chatbot** | Python / LangChain / Quart | 5002 | AI chatbot with MCP server |
| **mailhog** | Go | 8025 (UI), 1025 (SMTP) | Email capture for testing |
| **postgresdb** | PostgreSQL 14 | 5432 | Primary relational database |
| **mongodb** | MongoDB 4.4 | 27017 | Document storage |
| **chromadb** | ChromaDB | 8000 (internal) | Vector database for chatbot |
| **gateway-service** | Nginx | 443 | External API gateway (api.mypremiumdealership.com) |

## Build & Run Commands

### Docker Compose (Primary Method)

```bash
# Build all Docker images from source
cd deploy/docker && ./build-all.sh

# Start all services
cd deploy/docker
docker compose -f docker-compose.yml --compatibility up -d

# Stop services
docker compose down

# Use prebuilt images (skip local build)
docker compose pull
docker compose -f docker-compose.yml --compatibility up -d

# Expose to all interfaces (default is 127.0.0.1)
LISTEN_IP="0.0.0.0" docker compose -f docker-compose.yml --compatibility up -d
```

### Individual Service Development

**Identity Service (Java):**
```bash
cd services/identity
./gradlew build                    # Build
./gradlew test                     # Run tests
./gradlew bootRun                  # Run locally
./gradlew spotlessApply            # Format code
./build-image.sh                   # Build Docker image
```

**Workshop Service (Python/Django):**
```bash
cd services/workshop
pip install -r requirements.txt
python manage.py migrate           # Run migrations
python manage.py test              # Run tests
python manage.py runserver         # Run locally
./build-image.sh                   # Build Docker image
```

**Community Service (Go):**
```bash
cd services/community
go build                           # Build
go test ./...                      # Run tests
./build-image.sh                   # Build Docker image
```

**Web Service (React):**
```bash
cd services/web
npm install
npm start                          # Development server
npm run build                      # Production build
npm test                           # Run tests
npm run lint                       # Check formatting
npm run lint:fix                   # Fix formatting
./build-image.sh                   # Build Docker image
```

**Chatbot Service (Python):**
```bash
cd services/chatbot
pip install -r requirements.txt
# Requires CHATBOT_OPENAI_API_KEY environment variable
./build-image.sh                   # Build Docker image
```

### Kubernetes/Helm Deployment

```bash
# Using Helm charts
cd deploy/helm
helm install --namespace crapi crapi . --values values.yaml

# With persistent volume paths
helm install --namespace crapi crapi . --values values-pv.yaml

# Services default to ClusterIP (in-cluster only). crAPI is vulnerable by
# design, so reach the UI via port-forward rather than a public endpoint:
kubectl port-forward -n crapi svc/crapi-web 8888:80     # crAPI:   http://localhost:8888
kubectl port-forward -n crapi svc/mailhog-web 8025:8025 # Mailhog: http://localhost:8025

# To deliberately expose it (e.g. minikube), opt into NodePort/LoadBalancer:
helm install --namespace crapi crapi . --values values.yaml \
  --set web.service.type=NodePort --set mailhog.webService.type=NodePort
minikube tunnel --alsologtostderr                       # only needed for type=LoadBalancer
echo "http://$(minikube ip):30080"                      # crAPI URL  (NodePort)
echo "http://$(minikube ip):30025"                      # Mailhog URL (NodePort)
```

## Key URLs (Local Docker)

- **Application:** http://localhost:8888
- **Mailhog (email viewer):** http://localhost:8025
- **HTTPS:** https://localhost:8443

## Environment Configuration

Main configuration in `deploy/docker/.env`:

| Variable | Default | Description |
|----------|---------|-------------|
| `VERSION` | latest | Docker image version tag |
| `LISTEN_IP` | 127.0.0.1 | Interface to bind services |
| `TLS_ENABLED` | true | Enable HTTPS |
| `ENABLE_SHELL_INJECTION` | false | Enable shell injection vulnerability |
| `ENABLE_LOG4J` | false | Enable Log4j vulnerability |
| `LOG_LEVEL` | INFO | Logging verbosity |

Custom JWKS keys can be provided via `deploy/docker/keys/jwks.json`.

## Code Structure

```
services/
├── identity/           # Java Spring Boot
│   ├── src/main/java/com/crapi/
│   │   ├── controller/     # REST endpoints
│   │   ├── service/        # Business logic
│   │   ├── repository/     # JPA repositories
│   │   ├── entity/         # Database entities
│   │   └── config/         # Security, JWT, mail config
│   └── build.gradle.kts
├── workshop/           # Python Django
│   ├── crapi/
│   │   ├── mechanic/       # Mechanic endpoints
│   │   ├── merchant/       # Merchant endpoints
│   │   ├── shop/           # Shop/orders
│   │   └── user/           # User profile
│   └── crapi_site/         # Django settings
├── community/          # Go
│   ├── api/
│   │   ├── controllers/    # HTTP handlers
│   │   ├── models/         # Data models
│   │   ├── router/         # Route definitions
│   │   └── config/         # DB initialization
│   └── main.go
├── web/                # React TypeScript
│   ├── src/
│   │   ├── components/     # React components
│   │   ├── containers/     # Redux-connected components
│   │   ├── actions/        # Redux actions
│   │   └── constants/      # API endpoints, messages
│   └── package.json
├── chatbot/            # Python LangChain
│   └── src/
│       ├── chatbot/        # Chat service with LangGraph
│       └── mcpserver/      # MCP server implementation
└── gateway-service/    # Nginx reverse proxy
```

## API Specification

OpenAPI spec available at `openapi-spec/crapi-openapi-spec.json`

## Security Challenges

The application contains 18+ intentional vulnerabilities including:
- BOLA (Broken Object Level Authorization)
- Broken User Authentication
- Excessive Data Exposure
- Rate Limiting issues
- BFLA (Broken Function Level Authorization)
- Mass Assignment
- SSRF
- NoSQL/SQL Injection
- JWT vulnerabilities
- LLM prompt injection

See `docs/challenges.md` for full challenge list and `docs/challengeSolutions.md` for solutions.

## Database Access

Default credentials (from docker-compose):
- **PostgreSQL:** admin / crapisecretpassword (database: crapi)
- **MongoDB:** admin / crapisecretpassword (database: crapi)

## Notes

- All emails from domains `@example.com` route to Mailhog regardless of SMTP configuration
- The chatbot requires an OpenAI API key (`CHATBOT_OPENAI_API_KEY` environment variable)
- TLS certificates are self-signed and located in `services/*/certs/`
- Windows users should clone with `--config core.autocrlf=input`
