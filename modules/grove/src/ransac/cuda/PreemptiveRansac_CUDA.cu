/**
 * grove: PreemptiveRansac_CUDA.cu
 * Copyright (c) Torr Vision Group, University of Oxford, 2017. All rights reserved.
 */

#include "ransac/cuda/PreemptiveRansac_CUDA.h"

#include <thrust/device_ptr.h>
#include <thrust/sort.h>

#include <spaint/util/MemoryBlockFactory.h>
using spaint::MemoryBlockFactory;

#include "ransac/shared/PreemptiveRansac_Shared.h"

using namespace tvgutil;

namespace grove {

namespace
{
__global__ void ck_init_random_generators(CUDARNG *randomGenerators,
    uint32_t nbStates, uint32_t seed)
{
  int idx = threadIdx.x + blockIdx.x * blockDim.x;

  if (idx >= nbStates)
    return;

  randomGenerators[idx].reset(seed, idx);
}

template<typename RNG>
__global__ void ck_generate_pose_candidates(const Keypoint3DColour *keypoints,
    const Prediction3DColour *predictions, const Vector2i imgSize,
    RNG *randomGenerators, PoseCandidate *poseCandidates, int *nbPoseCandidates,
    int maxNbPoseCandidates,
    bool m_useAllModesPerLeafInPoseHypothesisGeneration,
    bool m_checkMinDistanceBetweenSampledModes,
    float m_minDistanceBetweenSampledModes,
    bool m_checkRigidTransformationConstraint,
    float m_translationErrorMaxForCorrectPose)
{
  const int candidateIdx = blockIdx.x * blockDim.x + threadIdx.x;

  if (candidateIdx >= maxNbPoseCandidates)
    return;

  PoseCandidate candidate;

  bool valid = preemptive_ransac_generate_candidate(keypoints, predictions,
      imgSize, randomGenerators[candidateIdx], candidate,
      m_useAllModesPerLeafInPoseHypothesisGeneration,
      m_checkMinDistanceBetweenSampledModes, m_minDistanceBetweenSampledModes,
      m_checkRigidTransformationConstraint,
      m_translationErrorMaxForCorrectPose);

  if (valid)
  {
    const int candidateIdx = atomicAdd(nbPoseCandidates, 1);
    poseCandidates[candidateIdx] = candidate;
  }
}

__global__ void ck_compute_energies(const Keypoint3DColour *keypoints,
    const Prediction3DColour *predictions, const int *inlierIndices,
    uint32_t nbInliers, PoseCandidate *poseCandidates, int nbCandidates)
{
  const int tId = threadIdx.x;
  const int threadsPerBlock = blockDim.x;
  const int candidateIdx = blockIdx.x;

  if (candidateIdx >= nbCandidates)
  {
    // Candidate has been trimmed, entire block returns,
    // does not cause troubles with the following __syncthreads()
    return;
  }

  PoseCandidate &currentCandidate = poseCandidates[candidateIdx];

  float localEnergy = preemptive_ransac_compute_candidate_energy(
      currentCandidate.cameraPose, keypoints, predictions, inlierIndices,
      nbInliers, tId, threadsPerBlock);

  // Now reduce by shuffling down the local energies
  //(localEnergy for thread 0 in the warp contains the sum for the warp)
  for (int offset = warpSize / 2; offset > 0; offset /= 2)
    localEnergy += __shfl_down(localEnergy, offset);

  // Thread 0 of each warp updates the final energy
  if ((threadIdx.x & (warpSize - 1)) == 0)
    atomicAdd(&currentCandidate.energy, localEnergy);

  __syncthreads(); // Wait for all threads in the block

  // tId 0 computes the final energy
  if (tId == 0)
    currentCandidate.energy = currentCandidate.energy
        / static_cast<float>(nbInliers);
}

__global__ void ck_reset_candidate_energies(PoseCandidate *poseCandidates,
    int nbPoseCandidates)
{
  const int candidateIdx = threadIdx.x;

  if (candidateIdx >= nbPoseCandidates)
  {
    return;
  }

  poseCandidates[candidateIdx].energy = 0.f;
}

template<bool useMask, typename RNG>
__global__ void ck_sample_inliers(const Keypoint3DColour *keypointsData,
    const Prediction3DColour *predictionsData, const Vector2i imgSize,
    RNG *randomGenerators, int *inlierIndices, int *inlierCount,
    int nbMaxSamples, int *inlierMaskData = NULL)
{
  const int sampleIdx = blockIdx.x * blockDim.x + threadIdx.x;

  if (sampleIdx >= nbMaxSamples)
    return;

  const int sampledLinearIdx = preemptive_ransac_sample_inlier<useMask>(
      keypointsData, predictionsData, imgSize, randomGenerators[sampleIdx],
      inlierMaskData);

  if (sampledLinearIdx >= 0)
  {
    const int outIdx = atomicAdd(inlierCount, 1);
    inlierIndices[outIdx] = sampledLinearIdx;
  }
}
}

PreemptiveRansac_CUDA::PreemptiveRansac_CUDA() :
    PreemptiveRansac()
{
  MemoryBlockFactory &mbf = MemoryBlockFactory::instance();
  m_randomGenerators = mbf.make_block<CUDARNG>(m_nbMaxPoseCandidates);
  m_rngSeed = 42;
  m_nbPoseCandidates_device = mbf.make_image<int>(Vector2i(1, 1));
  m_nbSampledInliers_device = mbf.make_image<int>(Vector2i(1, 1));

  init_random();
}

void PreemptiveRansac_CUDA::init_random()
{
  CUDARNG *randomGenerators = m_randomGenerators->GetData(MEMORYDEVICE_CUDA);

  // Initialize random states
  dim3 blockSize(256);
  dim3 gridSize((m_nbMaxPoseCandidates + blockSize.x - 1) / blockSize.x);

  ck_init_random_generators<<<gridSize, blockSize>>>(randomGenerators, m_nbMaxPoseCandidates, m_rngSeed);
}

void PreemptiveRansac_CUDA::generate_pose_candidates()
{
  const Vector2i imgSize = m_keypointsImage->noDims;
  const Keypoint3DColour *keypoints = m_keypointsImage->GetData(
      MEMORYDEVICE_CUDA);
  const Prediction3DColour *predictions = m_predictionsImage->GetData(
      MEMORYDEVICE_CUDA);

  CUDARNG *randomGenerators = m_randomGenerators->GetData(MEMORYDEVICE_CUDA);
  PoseCandidate *poseCandidates = m_poseCandidates->GetData(MEMORYDEVICE_CUDA);
  int *nbPoseCandidates = m_nbPoseCandidates_device->GetData(MEMORYDEVICE_CUDA);

  dim3 blockSize(32);
  dim3 gridSize((m_nbMaxPoseCandidates + blockSize.x - 1) / blockSize.x);

  // Reset number of candidates (only on device, the host number will be updated later)
  ORcudaSafeCall(cudaMemsetAsync(nbPoseCandidates, 0, sizeof(int)));

  ck_generate_pose_candidates<<<gridSize, blockSize>>>(keypoints, predictions, imgSize, randomGenerators,
      poseCandidates, nbPoseCandidates, m_nbMaxPoseCandidates,
      m_useAllModesPerLeafInPoseHypothesisGeneration,
      m_checkMinDistanceBetweenSampledModes, m_minSquaredDistanceBetweenSampledModes,
      m_checkRigidTransformationConstraint,
      m_translationErrorMaxForCorrectPose);
  ORcudaKernelCheck;

  // Need to make the data available to the host
  m_poseCandidates->dataSize = m_nbPoseCandidates_device->GetElement(0,
      MEMORYDEVICE_CUDA);
  m_poseCandidates->UpdateHostFromDevice();

  // Now perform kabsch on the candidates
  //#ifdef ENABLE_TIMERS
  //    boost::timer::auto_cpu_timer t(6,
  //        "kabsch: %ws wall, %us user + %ss system = %ts CPU (%p%)\n");
  //#endif
  compute_candidate_poses_kabsch();

  // Make the computed poses available to device
  m_poseCandidates->UpdateDeviceFromHost();
}

void PreemptiveRansac_CUDA::compute_and_sort_energies()
{
  const size_t nbPoseCandidates = m_poseCandidates->dataSize;

  const Keypoint3DColour *keypoints = m_keypointsImage->GetData(
      MEMORYDEVICE_CUDA);
  const Prediction3DColour *predictions = m_predictionsImage->GetData(
      MEMORYDEVICE_CUDA);
  const size_t nbInliers = m_inliersIndicesImage->dataSize;
  const int *inliers = m_inliersIndicesImage->GetData(MEMORYDEVICE_CUDA);
  PoseCandidate *poseCandidates = m_poseCandidates->GetData(MEMORYDEVICE_CUDA);

  ck_reset_candidate_energies<<<1, nbPoseCandidates>>>(poseCandidates, nbPoseCandidates);
  ORcudaKernelCheck;

  dim3 blockSize(128); // threads to compute the energy for each candidate
  dim3 gridSize(nbPoseCandidates); // Launch one block per candidate (many blocks will exit immediately in the later stages of ransac)
  ck_compute_energies<<<gridSize, blockSize>>>(keypoints, predictions, inliers, nbInliers, poseCandidates, nbPoseCandidates);
  ORcudaKernelCheck;

  throw std::runtime_error("build fails with the following thrust call");

//  // Sort by ascending energy
//  thrust::device_ptr<PoseCandidate> candidatesStart(poseCandidates);
//  thrust::device_ptr<PoseCandidate> candidatesEnd(
//      poseCandidates + nbPoseCandidates);
//  thrust::sort(candidatesStart, candidatesEnd, &test);
}

void PreemptiveRansac_CUDA::sample_inlier_candidates(bool useMask)
{
  const Vector2i imgSize = m_keypointsImage->noDims;
  const Keypoint3DColour *keypointsData = m_keypointsImage->GetData(
      MEMORYDEVICE_CUDA);
  const Prediction3DColour *predictionsData = m_predictionsImage->GetData(
      MEMORYDEVICE_CUDA);

  int *nbInlier_device = m_nbSampledInliers_device->GetData(MEMORYDEVICE_CUDA);
  int *inlierMaskData = m_inliersMaskImage->GetData(MEMORYDEVICE_CUDA);
  int *inlierIndicesData = m_inliersIndicesImage->GetData(MEMORYDEVICE_CUDA);
  CUDARNG *randomGenerators = m_randomGenerators->GetData(MEMORYDEVICE_CUDA);

  // Only if the number of inliers (host side) is zero, we clear the device number.
  // The assumption is that the number on device memory will remain in sync with the host
  // since only this method is allowed to modify it.
  if (m_inliersIndicesImage->dataSize == 0)
  {
    ORcudaSafeCall(cudaMemsetAsync(nbInlier_device, 0, sizeof(int)));
  }

  dim3 blockSize(128);
  dim3 gridSize((m_batchSizeRansac + blockSize.x - 1) / blockSize.x);

  if (useMask)
  {
    ck_sample_inliers<true> <<<gridSize,blockSize>>>(keypointsData, predictionsData, imgSize,
        randomGenerators, inlierIndicesData, nbInlier_device, m_batchSizeRansac,
        inlierMaskData);
    ORcudaKernelCheck;
  }
  else
  {
    ck_sample_inliers<false><<<gridSize,blockSize>>>(keypointsData, predictionsData, imgSize,
        randomGenerators, inlierIndicesData, nbInlier_device,
        m_batchSizeRansac);
    ORcudaKernelCheck;
  }

  // Make the selected inlier indices available to the cpu
  m_inliersIndicesImage->dataSize = m_nbSampledInliers_device->GetElement(0,
      MEMORYDEVICE_CUDA); // Update the number of inliers
}

void PreemptiveRansac_CUDA::update_candidate_poses()
{
  m_poseCandidates->UpdateHostFromDevice();
  m_inliersIndicesImage->UpdateHostFromDevice();

  PreemptiveRansac::update_candidate_poses();

  m_poseCandidates->UpdateDeviceFromHost();
}

}