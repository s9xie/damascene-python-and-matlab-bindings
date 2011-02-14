/*
 * Written by Andreas Mueller
 * 
 *
 * Compute gPB operator using damascene with cuda
 *
 *
 */

#include <stdlib.h>
#include <stdio.h>
#include <cuda.h>
#include <cutil.h>
#include <fcntl.h>
#include <float.h>
#include <unistd.h>
#include "texton.h"
#include "convert.h"
#include "intervening.h"
#include "lanczos.h"
#include "stencilMVM.h"

#include "localcues.h"
#include "combine.h"
#include "nonmax.h"
#include "spectralPb.h"
#include "globalPb.h"
#include "skeleton.h"

#define TEXTON64 2
#define TEXTON32 1

void gpb(const unsigned int* in_image,int width, int height, unsigned int* out_image)
{
	unsigned int totalMemory, availableMemory;
	cuMemGetInfo(&availableMemory,&totalMemory );
	printf("Available %u bytes on GPU\n", availableMemory);

	//copy in_image to device:
	uint imageSize = sizeof(uint) * width * height;
	uint* devRgbU=NULL;
	cudaMalloc((void**)devRgbU, imageSize);
	cudaMemcpy(devRgbU, in_image, imageSize, cudaMemcpyHostToDevice);

	float* devGreyscale;
	rgbUtoGreyF(width, height, devRgbU, &devGreyscale);

	int nEigNum = 9;
	float fEigTolerance = 1e-3;
	int nTextonChoice = TEXTON32;
	int nPixels = width * height;

	int* devTextons;
	findTextons(width, height, devGreyscale, &devTextons, nTextonChoice);
	float* devL;
	float* devA;
	float* devB;
	rgbUtoLab3F(width, height, 2.5, devRgbU, &devL, &devA, &devB);
	normalizeLab(width, height, devL, devA, devB);
	int border = 30;
	int borderWidth = width + 2 * border;
	int borderHeight = height + 2 * border;
	float* devLMirrored;
	mirrorImage(width, height, border, devL, &devLMirrored);
	cudaThreadSynchronize();
	cudaFree(devRgbU);
	cudaFree(devGreyscale);
	float* devBg;
	float* devCga;
	float* devCgb;
	float* devTg;
	int matrixPitchInFloats;
	localCues(width, height, devL, devA, devB, devTextons, &devBg, &devCga, &devCgb, &devTg, &matrixPitchInFloats, nTextonChoice);
	cudaFree(devTextons);
	cudaFree(devL);
	cudaFree(devA);
	cudaFree(devB);
	float* devMPbO;
	float *devCombinedGradient;
	combine(width, height, matrixPitchInFloats, devBg, devCga, devCgb, devTg, &devMPbO, &devCombinedGradient, nTextonChoice);
	CUDA_SAFE_CALL(cudaFree(devBg));
	CUDA_SAFE_CALL(cudaFree(devCga));
	CUDA_SAFE_CALL(cudaFree(devCgb));
	CUDA_SAFE_CALL(cudaFree(devTg));

	float* devMPb;
	cudaMalloc((void**)&devMPb, sizeof(float) * nPixels);
	nonMaxSuppression(width, height, devMPbO, matrixPitchInFloats, devMPb);
	//int devMatrixPitch = matrixPitchInFloats * sizeof(float);
	int radius = 5;
	//int radius = 10;

	Stencil theStencil(radius, width, height, matrixPitchInFloats);
	int nDimension = theStencil.getStencilArea();
	float* devMatrix;
	intervene(theStencil, devMPb, &devMatrix);
	printf("Intervening contour completed\n");

	float* eigenvalues;
	float* devEigenvectors;
	//int nEigNum = 17;
	generalizedEigensolve(theStencil, devMatrix, matrixPitchInFloats, nEigNum, &eigenvalues, &devEigenvectors, fEigTolerance);
	float* devSPb = 0;
	size_t devSPb_pitch = 0;
	CUDA_SAFE_CALL(cudaMallocPitch((void**)&devSPb, &devSPb_pitch, nPixels *  sizeof(float), 8));
	cudaMemset(devSPb, 0, matrixPitchInFloats * sizeof(float) * 8);

	spectralPb(eigenvalues, devEigenvectors, width, height, nEigNum, devSPb, matrixPitchInFloats);
	float* devGPb = 0;
	CUDA_SAFE_CALL(cudaMalloc((void**)&devGPb, sizeof(float) * nPixels));
	float* devGPball = 0;
	CUDA_SAFE_CALL(cudaMalloc((void**)&devGPball, sizeof(float) * matrixPitchInFloats * 8));
	//StartCalcGPb(nPixels, matrixPitchInFloats, 8, devbg1, devbg2, devbg3, devcga1, devcga2, devcga3, devcgb1, devcgb2, devcgb3, devtg1, devtg2, devtg3, devSPb, devMPb, devGPball, devGPb);
	StartCalcGPb(nPixels, matrixPitchInFloats, 8, devCombinedGradient, devSPb, devMPb, devGPball, devGPb);
	float* devGPb_thin = 0;
	CUDA_SAFE_CALL(cudaMalloc((void**)&devGPb_thin, nPixels * sizeof(float) ));
	PostProcess(width, height, width, devGPb, devMPb, devGPb_thin); //note: 3rd param width is the actual pitch of the image
	NormalizeGpbAll(nPixels, 8, matrixPitchInFloats, devGPball);

	cudaThreadSynchronize();
	printf("CUDA Status : %s\n", cudaGetErrorString(cudaGetLastError()));
	float* hostGPb = (float*)malloc(sizeof(float)*nPixels);
	memset(hostGPb, 0, sizeof(float) * nPixels);
	cudaMemcpy(out_image, devGPb, sizeof(float)*nPixels, cudaMemcpyDeviceToHost);

	//cutSavePGMf(outputPGMfilename, hostGPb, width, height);
	//writeFile(outputPBfilename, width, height, hostGPb);

	/* thin image */
	//float* hostGPb_thin = (float*)malloc(sizeof(float)*nPixels);
	//memset(hostGPb_thin, 0, sizeof(float) * nPixels);
	//cudaMemcpy(hostGPb_thin, devGPb_thin, sizeof(float)*nPixels, cudaMemcpyDeviceToHost);
	//cutSavePGMf(outputthinPGMfilename, hostGPb_thin, width, height);
	//writeFile(outputthinPBfilename, width, height, hostGPb);
	//free(hostGPb_thin);
	/* end thin image */

	//float* hostGPbAll = (float*)malloc(sizeof(float) * matrixPitchInFloats * 8);
	//cudaMemcpy(hostGPbAll, devGPball, sizeof(float) * matrixPitchInFloats * 8, cudaMemcpyDeviceToHost);
	//int oriMap[] = {3, 2, 1, 0, 7, 6, 5, 4};
	//float* hostGPbAllConcat = (float*)malloc(sizeof(float) * width * height * 8);
	//for(int i = 0; i < 8; i++) {
	//transpose(width, height, hostGPbAll + matrixPitchInFloats * oriMap[i], hostGPbAllConcat + width * height * i);
	//}
	//int dim[3];
	//dim[0] = 8; 
	//dim[1] = width;
	//dim[2] = height;

	//writeArray(outputgpbAllfilename, 3, dim, hostGPbAllConcat);

	free(hostGPb);
	//free(hostGPbAll);
	//free(hostGPbAllConcat);


	CUDA_SAFE_CALL(cudaFree(devEigenvectors));
	CUDA_SAFE_CALL(cudaFree(devCombinedGradient));
	CUDA_SAFE_CALL(cudaFree(devSPb));
	CUDA_SAFE_CALL(cudaFree(devGPb));
	CUDA_SAFE_CALL(cudaFree(devGPb_thin));
	CUDA_SAFE_CALL(cudaFree(devGPball));

}
