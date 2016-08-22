/**
 * spaint: PropagationComponent.h
 * Copyright (c) Torr Vision Group, University of Oxford, 2016. All rights reserved.
 */

#ifndef H_SPAINT_PROPAGATIONCOMPONENT
#define H_SPAINT_PROPAGATIONCOMPONENT

#include <ITMLib/Objects/RenderStates/ITMRenderState.h>
#include <ITMLib/Utils/ITMLibSettings.h>

#include "PropagationContext.h"
#include "../propagation/interface/LabelPropagator.h"

namespace spaint {

/**
 * \brief An instance of this pipeline component can be used to propagate a specified label over surfaces in a scene.
 */
class PropagationComponent
{
  //#################### TYPEDEFS ####################
private:
  typedef boost::shared_ptr<const ITMLib::ITMRenderState> RenderState_CPtr;
  typedef boost::shared_ptr<const ITMLib::ITMLibSettings> Settings_CPtr;

  //#################### PRIVATE VARIABLES ####################
private:
  /** The shared context needed for propagation. */
  PropagationContext_Ptr m_context;

  /** The label propagator. */
  LabelPropagator_CPtr m_labelPropagator;

  //#################### CONSTRUCTORS ####################
public:
  /**
   * \brief Constructs a propagation component.
   *
   * \param context The shared context needed for propagation.
   */
  explicit PropagationComponent(const PropagationContext_Ptr& context);

  //#################### PUBLIC MEMBER FUNCTIONS ####################
public:
  /**
   * \brief Runs the propagation component, propagating a semantic label over the surfaces of the target scene.
   *
   * \param renderState The render state associated with the camera position from which to propagate.
   */
  virtual void run(const RenderState_CPtr& renderState);
};

//#################### TYPEDEFS ####################

typedef boost::shared_ptr<PropagationComponent> PropagationComponent_Ptr;

}

#endif
