import uvicorn
from starlette.middleware import Middleware
from starlette.middleware.cors import CORSMiddleware

from wms_mcp.mcp_server import mcp

app = mcp.http_app(
    transport="http",
    json_response=True,
    stateless_http=True,
    middleware=[
        Middleware(
            CORSMiddleware,
            allow_origins=["*"],
            allow_methods=["*"],
            allow_headers=["*"],
        )
    ],
)

if __name__ == "__main__":
    import logging

    logging.basicConfig(level=logging.INFO)
    from wms_mcp.config import SERVER_PORT, log_config_summary

    log_config_summary()
    uvicorn.run(app, host="0.0.0.0", port=SERVER_PORT, lifespan="on")
