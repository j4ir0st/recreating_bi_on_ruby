# Dashboard de Comisiones - Proyecto Ruby on Rails

Este proyecto emula un Dashboard de Power BI desarrollado en Ruby on Rails y Docker, consumiendo datos de una API externa (Django Rest Framework).

## 🚀 Requisitos de Instalación

- Docker y Docker Desktop
- Sistema Operativo Windows (probado en Windows con Docker Desktop)

### 1. Iniciar el Proyecto

Ejecuta el siguiente comando en la raíz del proyecto para construir y levantar los contenedores:

```bash
docker compose up --build
```

### 2. Acceder al Dashboard

Abre tu navegador y visita:

- **Frontend**: [http://localhost:3000](http://localhost:3000)
- **Login**: Serás redirigido a la pantalla de inicio de sesión.
  - **Credenciales**: Usa el mismo usuario y contraseña que tienes configurado en tu API Django.
  - El sistema validará tus credenciales contra `http://localhost:8002/api/token/` y obtendrá un token de acceso.

- **API (Django)**: Asegúrate de tener tu API Django corriendo en el puerto 8002 (`http://localhost:8002`).

## 🛠️ Estructura del Proyecto

### Backend (Rails)
- **API Client**: `app/services/api_client.rb` - Handles communication with `appsurgicorperu.com` (o localhost).
- **Controlador**: `app/controllers/dashboard_controller.rb` - Procesa datos, filtros y KPIs.
- **Modelos**: No se usa base de datos SQL local; los datos vienen de la API externa.

### Frontend (Vistas)
- **Layout**: `app/views/layouts/application.html.erb` - Contiene estilos CSS premium modo oscuro y Scripts.
- **Vistas Parciales**:
  - `_panel.html.erb`: Tabla de facturas detallada.
  - `_vendedor.html.erb`: Resumen por vendedor.
  - `_reporte.html.erb`: Gráficos interactivos de evolución mensual.
- **Lógica JS**: Controladores Stimulus (`dashboard`, `chart`) en el layout.

## 📝 Características Implementadas

1.  **Conexión API**: Cliente HTTP robusto con autenticación JWT (vía Django) y paginación.
2.  **Dashboard Interactivo**: Filtros por fecha y vendedor sin recargar la página completa (Turbo Frames).
3.  **Gráficos**: Visualización de métricas mensuales y **diarias** (cuando se selecciona un mes) usando Chart.js y Stimulus.
4.  **Estilo Power BI**: Diseño oscuro, tarjetas KPI, tablas con scroll y badges de estado.
5.  **Filtros Inteligentes**:
    - Fechas: Todo el año actual (2026-01 a 2026-12).
    - Estado: Solo muestra facturas pagadas (`cancelado == 'S'`).

## 🔧 Resolución de Problemas

- Si el gráfico no carga: Asegúrate de navegar entre pestañas. El controlador Stimulus se encarga de re-inicializarlo.
- Si no hay datos: Verifica que la API Django esté corriendo en `localhost:8002` y responda a credenciales `usuario:cliente123`.

---
Desarrollado con Ruby 3.2.2 y Rails 7.2.3
