PROJECT_NAME = ton_app
APP_WORKERS = 1
TEST_PATH = ./tests

PIP = .venv/bin/pip
POETRY = .venv/bin/poetry
PYTEST = .venv/bin/pytest
COVERAGE = .venv/bin/coverage
RUFF = .venv/bin/ruff
MYPY = .venv/bin/mypy

HARBOR_USERNAME ?=
HARBOR_PASSWORD ?=
HARBOR_REGISTRY ?=
IMAGE_NAME ?= industry/backend/web_industry
TAG = $(shell git rev-parse --short=8 HEAD)

ENCRYPTED_FILE ?= .env.enc
DECRYPTED_FILE ?= .env.prod
DECRYPTED_SECRET ?=

.PHONY: help lint develop clean_dev local local_down docker-apply-migrations test test-ci lint-ci ruff mypy clean_pycache app build encrypt_env decrypt_env

help:  ## Show this help
	@echo "Available commands:"
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/ /'

lint:  ## Lint project code.
	$(POETRY) run $(RUFF) check --fix .

develop: clean_dev  ## Create project virtual environment
	python3.12 -m venv .venv
	$(PIP) install -U pip poetry
	$(POETRY) config virtualenvs.create false
	$(POETRY) install
	$(POETRY) run pre-commit install

local:  ## Start local development environment
	docker compose -f docker-compose.dev.yaml up --build --force-recreate --remove-orphans --renew-anon-volumes

local_down: ## Stop local development containers and delete volumes
	docker compose -f docker-compose.dev.yaml down -v

local-create-migrations:
	.venv/bin/python -m $(PROJECT_NAME).infrastructure.database revision --autogenerate

local-apply-migrations:
	.venv/bin/python -m $(PROJECT_NAME).infrastructure.database upgrade head

docker-apply-migrations: ## Apply database migrations in Docker
	docker compose exec back python -m web_industry.infrastructure.database upgrade head

test: ## Run tests
	$(POETRY) run $(PYTEST) -vx $(TEST_PATH)

ruff: ## Run ruff linter
	$(POETRY) run $(RUFF) check ./$(PROJECT_NAME)

mypy: ## Run mypy type checker
	$(POETRY) run $(MYPY) ./$(PROJECT_NAME)

clean_dev: ## Clean up development environment
	rm -rf .venv/

clean_pycache: ## Remove Python cache directories
	find . -type d -name __pycache__ -exec rm -r {} \+

app:
	granian --workers $(APP_WORKERS) --host 0.0.0.0 --port 8002 --interface asgi web_industry.presentors.rest.main:app

build:  ## Build and push Docker image
	@echo -n "$(HARBOR_PASSWORD)" | docker login --username $(HARBOR_USERNAME) --password-stdin $(HARBOR_REGISTRY) || { echo "Docker login failed"; exit 1; }
	@docker build -t $(HARBOR_REGISTRY)/$(IMAGE_NAME):$(TAG) -f Dockerfile . || { echo "Docker build failed"; exit 1; }
	@docker push $(HARBOR_REGISTRY)/$(IMAGE_NAME):$(TAG)
	@echo "Pushing Docker image: $(HARBOR_REGISTRY)/$(IMAGE_NAME):$(TAG)"
	@docker logout $(HARBOR_REGISTRY)
	@echo "Build and push process completed."

encrypt_env: ## Encrypt environment variables file
	openssl enc -aes-256-cbc -salt -in $(DECRYPTED_FILE) -out $(ENCRYPTED_FILE) -k $(DECRYPTED_SECRET)
	@echo "$(DECRYPTED_FILE) encrypted as $(ENCRYPTED_FILE)"

decrypt_env: ## Decrypt environment variables file
	openssl enc -aes-256-cbc -d -in $(ENCRYPTED_FILE) -out $(DECRYPTED_FILE) -k $(DECRYPTED_SECRET)
	@echo "$(ENCRYPTED_FILE) decrypted to $(DECRYPTED_FILE)"

test-ci: ## Run tests with pytest and coverage in CI
	$(COVERAGE) run -m pytest $(TEST_PATH) -m "not s3" --junitxml=junit.xml -rs
	$(COVERAGE) report
	$(COVERAGE) xml

lint-ci: ## Run all linters in CI
	@$(MAKE) ruff
	@$(MAKE) mypy

build-ci:
	@$(MAKE) decrypt_env
	@$(MAKE) build
