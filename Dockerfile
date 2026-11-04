# Imagen base liviana de Python
FROM python:3.12-slim

# Buenas prácticas: sin .pyc y logs sin buffer (se ven en `kubectl logs`)
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=5001

WORKDIR /app

# Primero dependencias (aprovecha la caché de capas de Docker)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Luego el código
COPY app.py .
COPY templates ./templates

# Usuario sin privilegios
RUN useradd --create-home appuser
USER appuser

EXPOSE 5001

# Servidor WSGI de producción en lugar del servidor de desarrollo de Flask
CMD ["sh", "-c", "gunicorn --bind 0.0.0.0:${PORT} --workers 2 app:app"]
