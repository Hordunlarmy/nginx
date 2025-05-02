nginx: 
	@if systemctl is-active --quiet nginx; then \
		echo "[WARNING] NGINX is already running on the local server."; \
		read -p "Do you want to stop the existing NGINX service and continue (y/n)? " choice; \
		if [ "$$choice" = "y" ]; then \
			sudo systemctl stop nginx; \
			echo "[INFO] Stopped the existing NGINX service."; \
		else \
			echo "[INFO] Aborting the operation."; \
			exit 1; \
		fi; \
	fi

	@echo "[INFO] Checking if shared-network exists..."
	@if ! docker network inspect shared-network > /dev/null 2>&1; then \
		echo "[INFO] Creating shared-network..."; \
		docker network create shared-network; \
	else \
		echo "[INFO] shared-network already exists."; \
	fi
	docker compose up --build -d

stop:
	@echo "[INFO] Stopping NGINX container..."
	docker compose down

	@echo "[INFO] Removing shared-network..."
	@if docker network inspect shared-network > /dev/null 2>&1; then \
		CONTAINER_COUNT=$$(docker network inspect -f '{{len .Containers}}' shared-network); \
		if [ "$$CONTAINER_COUNT" -eq 0 ]; then \
			docker network rm shared-network; \
			echo "[INFO] shared-network removed."; \
		else \
			echo "[WARN] shared-network is still in use by $$CONTAINER_COUNT container(s). Not removing."; \
		fi \
	else \
		echo "[INFO] shared-network does not exist."; \
	fi

logs:
	@ENV_NAME=$${env:-dev}; \
	docker compose logs -f;


.PHONY: nginx stop

