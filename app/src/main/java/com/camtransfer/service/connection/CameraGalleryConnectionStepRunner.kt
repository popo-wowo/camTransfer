package com.camtransfer.service.connection

import com.camtransfer.service.CameraConnectionStep

interface CameraGalleryConnectionStepRunner<I, O> {
    val step: CameraConnectionStep

    suspend fun run(input: I): O
}
