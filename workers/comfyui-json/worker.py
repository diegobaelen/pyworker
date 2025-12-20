import random
import sys
import os
import subprocess

from vastai import Worker, WorkerConfig, HandlerConfig, LogActionConfig, BenchmarkConfig

# ComyUI model configuration
MODEL_SERVER_URL           = 'http://127.0.0.1'
MODEL_SERVER_PORT          = 18288
MODEL_LOG_FILE             = '/var/log/portal/comfyui.log'
MODEL_HEALTHCHECK_ENDPOINT = "/health"

# ComyUI-specific log messages
MODEL_LOAD_LOG_MSG = [
    "To see the GUI go to: "
]

MODEL_ERROR_LOG_MSGS = [
    "MetadataIncompleteBuffer",
    "Value not in list: ",
    "[ERROR] Provisioning Script failed"
]

MODEL_INFO_LOG_MSGS = [
    '"message":"Downloading'
]

benchmark_prompts = [
    "Cartoon hoodie hero; orc, anime cat, bunny; black goo; buff; vector on white.",
    "Cozy farming-game scene with fine details.",
    "2D vector child with soccer ball; airbrush chrome; swagger; antique copper.",
    "Realistic futuristic downtown of low buildings at sunset.",
    "Perfect wave front view; sunny seascape; ultra-detailed water; artful feel.",
    "Clear cup with ice, fruit, mint; creamy swirls; fluid-sim CGI; warm glow.",
    "Male biker with backpack on motorcycle; oilpunk; award-worthy magazine cover.",
    "Collage for textile; surreal cartoon cat in cap/jeans before poster; crisp.",
    "Medieval village inside glass sphere; volumetric light; macro focus.",
    "Iron Man with glowing axe; mecha sci-fi; jungle scene; dynamic light.",
    "Pope Francis DJ in leather jacket, mixing on giant console; dramatic.",
]



benchmark_dataset = [
    {
        "input": {
            "request_id": f"test-{random.randint(1000, 99999)}",
            "modifier": "Text2Image",
            "modifications": {
                "prompt": prompt,
                "width": 512,
                "height": 512,
                "steps": 20,
                "seed": random.randint(0, sys.maxsize)
            }
        }
    } for prompt in benchmark_prompts
]


def maybe_download_hunyuan3d_models():
    # Désactivable via env
    if os.getenv("DOWNLOAD_HUNYUAN3D_MODELS", "1") != "1":
        print("[hunyuan3d] DOWNLOAD_HUNYUAN3D_MODELS != 1, skipping.")
        return

    comfy_home = os.getenv("COMFY_HOME", "/workspace/ComfyUI")
    dit_path = os.path.join(comfy_home, "models", "diffusion_models", "hunyuan3d-dit-v2-1.ckpt")
    vae_path = os.path.join(comfy_home, "models", "vae", "hunyuan3d-vae-v2-1.ckpt")

    os.makedirs(os.path.dirname(dit_path), exist_ok=True)
    os.makedirs(os.path.dirname(vae_path), exist_ok=True)

    dit_url = os.getenv(
        "HUNYUAN_DIT_URL",
        "https://huggingface.co/tencent/Hunyuan3D-2.1/resolve/main/hunyuan3d-dit-v2-1/model.fp16.ckpt",
    )
    vae_url = os.getenv(
        "HUNYUAN_VAE_URL",
        "https://huggingface.co/tencent/Hunyuan3D-2.1/resolve/main/hunyuan3d-vae-v2-1/model.fp16.ckpt",
    )

    if not os.path.isfile(dit_path):
        print("[hunyuan3d] Downloading DIT checkpoint...")
        subprocess.check_call(["bash", "-lc", f"curl -L '{dit_url}' -o '{dit_path}'"])
    else:
        print("[hunyuan3d] DIT checkpoint already present.")

    if not os.path.isfile(vae_path):
        print("[hunyuan3d] Downloading VAE checkpoint...")
        subprocess.check_call(["bash", "-lc", f"curl -L '{vae_url}' -o '{vae_path}'"])
    else:
        print("[hunyuan3d] VAE checkpoint already present.")

    print("[hunyuan3d] Model download done.")


worker_config = WorkerConfig(
    model_server_url=MODEL_SERVER_URL,
    model_server_port=MODEL_SERVER_PORT,
    model_log_file=MODEL_LOG_FILE,
    model_healthcheck_url=MODEL_HEALTHCHECK_ENDPOINT,
    handlers=[
        HandlerConfig(
            route="/generate/sync",
            allow_parallel_requests=False,
            max_queue_time=10.0,
            benchmark_config=BenchmarkConfig(
                dataset=benchmark_dataset,
            )
        )
    ],
    log_action_config=LogActionConfig(
        on_load=MODEL_LOAD_LOG_MSG,
        on_error=MODEL_ERROR_LOG_MSGS,
        on_info=MODEL_INFO_LOG_MSGS
    )
)

maybe_download_hunyuan3d_models()
Worker(worker_config).run()
