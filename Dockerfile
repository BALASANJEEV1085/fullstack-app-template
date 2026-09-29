# ==============================================================
# Full-Stack App Template — Unified Production Dockerfile
# Builds React/Vite frontend + Spring Boot User Service (8080)
# + Spring Boot Booking Service (8081); serves all via Nginx:80
# ==============================================================

# ---------- Stage 1: Frontend build ----------
FROM node:20-alpine AS frontend-builder
WORKDIR /app/frontend
COPY frontend/package*.json ./
RUN npm install --legacy-peer-deps
COPY frontend/ .
ARG VITE_API_BASE_URL=""
ENV VITE_API_BASE_URL=$VITE_API_BASE_URL
RUN npm run build

# ---------- Stage 2: User Service (backend) build ----------
FROM maven:3.9-eclipse-temurin-17-alpine AS backend-builder
WORKDIR /app
COPY backend/pom.xml .
RUN mvn dependency:go-offline -B
COPY backend/src ./src
RUN mvn clean package -DskipTests -B

# ---------- Stage 3: Booking Service build ----------
FROM maven:3.9-eclipse-temurin-17-alpine AS backend-booking-builder
WORKDIR /app
COPY backend-booking/pom.xml .
RUN mvn dependency:go-offline -B
COPY backend-booking/src ./src
RUN mvn clean package -DskipTests -B

# ---------- Stage 4: Unified runtime ----------
FROM nginx:alpine AS runtime

# JRE for both Spring Boot services
RUN apk add --no-cache openjdk17-jre-headless curl su-exec && \
    mkdir -p /run/nginx /etc/nginx/http.d /etc/nginx/conf.d /app

# --- Backend runtime layout (full app dirs copied) ---
COPY --from=backend-builder /app/target/*.jar /app/user-service.jar
COPY --from=backend-booking-builder /app/target/*.jar /app/booking-service.jar

# --- Frontend static assets ---
COPY --from=frontend-builder /app/frontend/dist /usr/share/nginx/html

# --- Non-root user for Java processes ---
RUN addgroup -S appgroup && adduser -S appuser -G appgroup && \
    chown -R appuser:appgroup /app && \
    chown -R nginx:nginx /usr/share/nginx/html /var/cache/nginx

# --- Nginx config: SPA at /, API routed to both services ---
RUN printf '%s\n' \
'server {' \
'    listen 80;' \
'    server_name _;' \
'' \
'    root /usr/share/nginx/html;' \
'    index index.html;' \
'' \
'    # User Service API' \
'    location /api/v1/users {' \
'        proxy_pass http://127.0.0.1:8080;' \
'        proxy_set_header Host $host;' \
'        proxy_set_header X-Real-IP $remote_addr;' \
'        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;' \
'        proxy_set_header X-Forwarded-Proto $scheme;' \
'    }' \
'' \
'    # Booking Service API' \
'    location /api/v1/bookings {' \
'        proxy_pass http://127.0.0.1:8081;' \
'        proxy_set_header Host $host;' \
'        proxy_set_header X-Real-IP $remote_addr;' \
'        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;' \
'        proxy_set_header X-Forwarded-Proto $scheme;' \
'    }' \
'' \
'    # Swagger UIs (proxied for convenience)' \
'    location /swagger-ui.html {' \
'        proxy_pass http://127.0.0.1:8080;' \
'        proxy_set_header Host $host;' \
'    }' \
'    location ~ ^/(api-docs|swagger-ui) {' \
'        proxy_pass http://127.0.0.1:8080;' \
'        proxy_set_header Host $host;' \
'    }' \
'' \
'    # SPA fallback' \
'    location / {' \
'        try_files $uri $uri/ /index.html;' \
'    }' \
'' \
'    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2)$ {' \
'        expires 1y;' \
'        add_header Cache-Control "public, immutable";' \
'        try_files $uri =404;' \
'    }' \
'}' > /etc/nginx/http.d/default.conf && \
    rm -f /etc/nginx/conf.d/default.conf

EXPOSE 80

ENV SERVER_PORT=8080 \
    BOOKING_SERVER_PORT=8081 \
    SPRING_PROFILES_ACTIVE=default \
    DB_HOST=postgres \
    DB_PORT=5432 \
    DB_NAME=fullstack_db \
    DB_USERNAME=postgres \
    DB_PASSWORD=postgres

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -fsS http://localhost/ >/dev/null || exit 1

CMD ["sh", "-c", "mkdir -p /run/nginx && java -XX:+UseContainerSupport -XX:MaxRAMPercentage=35.0 -Djava.security.egd=file:/dev/./urandom -jar /app/user-service.jar & java -XX:+UseContainerSupport -XX:MaxRAMPercentage=35.0 -Djava.security.egd=file:/dev/./urandom -jar /app/booking-service.jar & exec nginx -g 'daemon off;'"]