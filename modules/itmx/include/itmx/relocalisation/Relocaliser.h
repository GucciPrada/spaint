/**
 * itmx: Relocaliser.h
 * Copyright (c) Torr Vision Group, University of Oxford, 2017. All rights reserved.
 */

#ifndef H_ITMX_RELOCALISER
#define H_ITMX_RELOCALISER

#include <boost/optional.hpp>
#include <boost/shared_ptr.hpp>

#include <ITMLib/Utils/ITMImageTypes.h>

#include <ORUtils/SE3Pose.h>

namespace itmx {

/**
 * \brief An instance of a class deriving from this one can be used to relocalise a camera in a 3D scene
 *        based on the current RGB-D input image.
 */
class Relocaliser
{
  //#################### ENUMERATIONS ####################
public:
  /**
   * \brief The values of this enumeration can be used to indicate the quality of a relocalised pose.
   */
  enum Quality
  {
    RELOCALISATION_GOOD,
    RELOCALISATION_POOR
  };

  //#################### NESTED TYPES ####################
public:
  /**
   * \brief An instance of this struct represents the results of a relocalisation call.
   */
  struct Result
  {
    //~~~~~~~~~~~~~~~~~~~~ PUBLIC MEMBER VARIABLES ~~~~~~~~~~~~~~~~~~~~

    /** The pose estimated by the relocaliser. */
    ORUtils::SE3Pose pose;

    /** The quality of the relocalisation. */
    Quality quality;
  };

  //#################### DESTRUCTOR ####################
public:
  /**
   * \brief Destroys a relocaliser.
   */
  virtual ~Relocaliser();

  //#################### PUBLIC ABSTRACT MEMBER FUNCTIONS ####################
public:
  /**
   * \brief Attempts to determine the location from which an RGB-D image pair was acquired,
   *        thereby relocalising the camera with respect to the 3D scene.
   *
   * \param colourImage     The colour image.
   * \param depthImage      The depth image.
   * \param depthIntrinsics The intrinsic parameters of the depth sensor.
   * \return                The result of the relocalisation, if successful, or boost::none otherwise.
   */
  virtual boost::optional<Result> relocalise(const ITMUChar4Image *colourImage, const ITMFloatImage *depthImage, const Vector4f& depthIntrinsics) const = 0;

  /**
   * \brief Resets the relocaliser, allowing the integration of information for a new area.
   */
  virtual void reset() = 0;

  /**
   * \brief Trains the relocaliser using information from an RGB-D image pair captured from a known pose in the world.
   *
   * \param colourImage     The colour image.
   * \param depthImage      The depth image.
   * \param depthIntrinsics The intrinsic parameters of the depth sensor.
   * \param cameraPose      The position of the camera in the world.
   */
  virtual void train(const ITMUChar4Image *colourImage, const ITMFloatImage *depthImage,
                     const Vector4f& depthIntrinsics, const ORUtils::SE3Pose& cameraPose) = 0;

  //#################### PUBLIC MEMBER FUNCTIONS ####################
public:
  /**
   * \brief Signals to the relocaliser that no more calls will be made to its train or update functions
   *        (unless and until the relocaliser is reset).
   *
   * \note This allows the relocaliser to release memory that is only used during training.
   * \note Later calls to train or update prior to a reset will result in undefined behaviour.
   */
  virtual void finish_training();

  /**
   * \brief Updates the contents of the relocaliser when spare processing time is available.
   *
   * This is intended to be overridden by derived relocalisers that need to perform bookkeeping operations.
   */
  virtual void update();
};

//#################### TYPEDEFS ####################

typedef boost::shared_ptr<Relocaliser> Relocaliser_Ptr;
typedef boost::shared_ptr<const Relocaliser> Relocaliser_CPtr;

}

#endif
