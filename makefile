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
	docker compose down -v
	@echo "[INFO] Removing shared-network..."
	@if docker network inspect shared-network > /dev/null 2>&1; then \
		docker network rm shared-network; \
		echo "[INFO] shared-network removed."; \
	else \
		echo "[INFO] shared-network does not exist."; \
	fi

.PHONY: nginx stop

