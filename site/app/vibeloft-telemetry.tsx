"use client";

import { useEffect } from "react";

const SCRIPT_ID = "vibeloft-telemetry";

export function VibeLoftTelemetry() {
  useEffect(() => {
    if (document.getElementById(SCRIPT_ID)) return;

    const script = document.createElement("script");
    script.id = SCRIPT_ID;
    script.defer = true;
    script.src = "https://vibeloft.ai/telemetry/v1.js";
    script.dataset.vlProductId = "0d5781ba-0024-4ef4-b25d-2853ee434456";
    script.dataset.vlAuthKey = "vl_web.ABms9507nd0NZCD_gPk4F__qMTs7kE__rxC1LJI94i4";
    document.head.append(script);
  }, []);

  return null;
}
